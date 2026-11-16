import html.parser
import pathlib
import os
import re
import subprocess
import tempfile
import unittest
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[2]
HARNESS = ROOT / "Widget" / "test" / "harness.html"
# CI and local verification can use the headless shell without launching a
# second copy of the person's desktop browser for every fixture.
CHROME = pathlib.Path(os.environ.get(
    "MACREMOTE_TEST_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
))


WIDGET = ROOT / "Widget" / "MacRemoteWidget.html"


class _AssetTagParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.external_scripts = []
        self.stylesheets = []
        self.iframes = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script" and values.get("src"):
            self.external_scripts.append(values["src"])
        if tag == "link" and values.get("rel") == "stylesheet":
            self.stylesheets.append(values.get("href"))
        if tag == "iframe":
            self.iframes.append(values.get("src"))


class MCPAppsWidgetSelfContainmentTests(unittest.TestCase):
    """The widget renders tool results inside the connected app. It must be one
    self-contained file that cannot load code or send data anywhere: no
    external scripts, stylesheets, or frames, and no network calls."""

    def test_widget_loads_nothing_and_calls_nothing(self):
        widget = WIDGET.read_text(encoding="utf-8")
        parser = _AssetTagParser()
        parser.feed(widget)

        self.assertFalse(parser.external_scripts)
        self.assertFalse(parser.stylesheets)
        self.assertFalse(parser.iframes)
        self.assertIsNone(re.search(r"\bfetch\s*\(", widget))
        self.assertIsNone(re.search(r"\bXMLHttpRequest\s*\(", widget))
        self.assertIsNone(re.search(r"\bnew\s+WebSocket\s*\(", widget))


@unittest.skipUnless(CHROME.is_file(), "Google Chrome is required for widget protocol tests")
class MCPAppsWidgetBrowserTests(unittest.TestCase):
    def test_reminder_receipts_across_delivery_and_partial_results(self):
        for fixture in ("remindertextfallback", "reminderpartial", "reminderbatch", "reminderdeletedrow"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(fixture=fixture, width=390, theme=theme)

    def test_chatgpt_compatibility_data_and_metadata_keep_the_receipt(self):
        for exercise in ("compatibility", "compatmetadata"):
            with self.subTest(exercise=exercise):
                self.render_harness(fixture="remindertextfallback", exercise=exercise, width=390)

    def test_table_sorting_preserves_order_across_controls_and_paging(self):
        for width in (390, 760):
            for theme in ("light", "dark"):
                with self.subTest(width=width, theme=theme):
                    self.render_harness(
                        fixture="sortrows", exercise="sort", width=width, theme=theme
                    )

    def render_harness(self, **query):
        url = HARNESS.as_uri() + "?" + urllib.parse.urlencode(query)
        with tempfile.TemporaryDirectory(prefix="macremote-widget-chrome-") as profile:
            command = [
                str(CHROME),
                "--headless=new",
                "--disable-background-networking",
                "--disable-default-apps",
                "--disable-gpu",
                "--no-first-run",
                "--allow-file-access-from-files",
                "--run-all-compositor-stages-before-draw",
                "--virtual-time-budget=3000",
                f"--user-data-dir={profile}",
                "--dump-dom",
                url,
            ]
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                stdout = completed.stdout
                stderr = completed.stderr
                self.assertEqual(completed.returncode, 0, stderr[-2000:])
            except subprocess.TimeoutExpired as error:
                # Chrome 150 prints the completed DOM but keeps its macOS
                # background process alive when a page owns an iframe.
                stdout = error.stdout or ""
                stderr = error.stderr or ""
                if isinstance(stdout, bytes):
                    stdout = stdout.decode("utf-8", errors="replace")
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", errors="replace")

        match = re.search(r"<output\b[^>]*\bid=\"assertions\"[^>]*>", stdout)
        self.assertIsNotNone(match, (stderr + stdout)[-3000:])
        self.assertIn('data-state="pass"', match.group(0), stdout[-3000:])
        self.assertIn("PASS", stdout)

    def test_core_render_and_server_tool_capability_gate(self):
        for server_tools in ("1", "0"):
            with self.subTest(serverTools=server_tools):
                self.render_harness(
                    fixture="table",
                    serverTools=server_tools,
                    openLinks="1",
                )

    def test_host_mediated_open_link(self):
        self.render_harness(
            fixture="podcasts",
            serverTools="1",
            openLinks="1",
            exercise="link",
        )

    def test_http_link_falls_back_to_a_safe_browser_anchor(self):
        self.render_harness(
            fixture="podcasts",
            serverTools="1",
            openLinks="0",
        )

    def test_partial_host_context_is_merged_and_applied(self):
        self.render_harness(
            fixture="table",
            theme="dark",
            serverTools="1",
            openLinks="1",
            exercise="context",
        )

    def test_text_stays_legible_when_host_theme_and_colors_disagree(self):
        # Every run checks that the root's color scheme follows the theme and
        # that the title, status line, caption, and dim text reach 4.5:1.
        # These variants add a host that sends the other theme's colors, one
        # that sends colors without naming a theme, one whose secondary text
        # is too faint for its background, and one whose secondary text
        # can't be measured. The last two must fall back to the widget's own.
        for host in ("mismatch", "themeless", "lowsecondary", "unmeasurable"):
            for theme in ("light", "dark"):
                with self.subTest(host=host, theme=theme):
                    self.render_harness(fixture="safefallback", theme=theme, host=host)

    def test_dim_text_reaches_contrast_in_both_themes(self):
        # Dim cells and completed rows (table) and queue positions (Up Next)
        # use the tertiary gray, which must reach 4.5:1 too.
        for fixture in ("table", "changeupnext"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(fixture=fixture, theme=theme)

    def test_malformed_messages_and_unknown_methods_are_safe(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="malformed",
        )

    def test_cancellation_reason_is_rendered_as_text(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="cancel",
        )

    def test_widget_action_uses_host_mediated_tools_call(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="action",
        )

    def test_every_json_structured_content_type_and_text_fallback_render_safely(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="jsonvalues",
        )

    def test_non_json_structured_content_is_ignored_without_losing_the_last_result(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="jsoninvalid",
        )

    def test_multi_group_payload_renders_curated_sections(self):
        # A payload with four row arrays used to fall to the raw key/value
        # tree; the harness asserts section order, the card group, the numbered
        # queue, the leftover scalar chip, and that no tree survives.
        for width in ("760", "390"):
            with self.subTest(width=width):
                self.render_harness(
                    fixture="triage",
                    width=width,
                    serverTools="1",
                    openLinks="1",
                )

    def test_artwork_the_host_blocks_leaves_a_visible_placeholder(self):
        # Artwork is the widget's only external resource, so it is the only
        # thing a host sandbox can refuse — and a refused image used to hide
        # itself, which is how a `resources/read` result that shipped no
        # `ui.csp` allowlist looked like a widget that just doesn't show
        # podcast artwork. Every row keeps its tile.
        self.render_harness(
            fixture="artworkblocked",
            serverTools="1",
            openLinks="1",
        )

    def test_all_empty_group_payload_renders_the_friendly_empty_line(self):
        # Same payload shape, nothing in any group: the widget must stay in the
        # grouped state and say so in one plain line — falling through to the
        # raw key/value tree here is the exact developer-facing view this
        # curation exists to remove.
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="emptygroups",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_queue_change_confirmation_renders_headline_and_resulting_queue(self):
        for fixture in ("changeupnext", "changeupnextdry"):
            with self.subTest(fixture=fixture):
                self.render_harness(
                    fixture=fixture,
                    serverTools="1",
                    openLinks="1",
                )

    def test_minimal_legacy_change_shape_stays_human_readable(self):
        self.render_harness(
            fixture="changeupnextlegacy",
            serverTools="1",
            openLinks="1",
        )

    def test_count_line_noun_comes_from_the_curation(self):
        # Same payload, no curated noun: the widget falls back to its own
        # generic word instead of a domain literal it has no business knowing.
        self.render_harness(
            fixture="changedefaultnoun",
            serverTools="1",
            openLinks="1",
        )

    def test_episode_state_writes_render_as_confirmations(self):
        # star used to be a raw tree; archive a table with zero surviving
        # columns — a literally blank result.
        for fixture in ("episodestar", "episodearchive", "episodetitledupe"):
            with self.subTest(fixture=fixture):
                self.render_harness(
                    fixture=fixture,
                    serverTools="1",
                    openLinks="1",
                )

    def test_search_results_split_into_curated_sections(self):
        for width in ("760", "390"):
            with self.subTest(width=width):
                self.render_harness(
                    fixture="searchgroups",
                    width=width,
                    serverTools="1",
                    openLinks="1",
                )

    def test_a_record_with_subtasks_stays_the_record(self):
        self.render_harness(
            fixture="reminderinfo",
            serverTools="1",
            openLinks="1",
        )

    def test_write_confirmations_name_what_changed(self):
        for fixture in (
            "remindercreated",
            "remindercreatedwarning",
            "reminderupdated",
            "reminderdeleted",
            "reminderflagged",
            "reminderunflagged",
            "habitcheck",
        ):
            with self.subTest(fixture=fixture):
                self.render_harness(
                    fixture=fixture,
                    serverTools="1",
                    openLinks="1",
                )

    def test_recurrence_and_flag_state_use_derived_human_labels(self):
        for width in ("760", "390"):
            with self.subTest(width=width):
                self.render_harness(
                    fixture="reminderrecurrence",
                    width=width,
                    serverTools="1",
                    openLinks="1",
                )

    def test_successful_partial_write_is_amber_and_keeps_its_warning_visible(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="remindercreatedwarning",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_flag_failure_stays_a_terminal_error(self):
        self.render_harness(
            fixture="reminderflagerror",
            serverTools="1",
            openLinks="1",
        )

    def test_a_definition_shaped_record_renders_without_object_object(self):
        self.render_harness(
            fixture="habitshow",
            serverTools="1",
            openLinks="1",
        )

    def test_nested_rows_context_and_copy_keep_the_complete_envelope(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="overrows",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                    exercise="copy",
                )

    def test_nested_write_preview_and_unverified_warning_are_truthful(self):
        for fixture in ("overdry", "overunverified"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                    )

    def test_note_markdown_and_transcript_documents_render_as_safe_text(self):
        for fixture in ("notesdocument", "notestranscripts"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                    )

    def test_note_rows_and_write_results_cover_the_complete_note_shape_matrix(self):
        for fixture in ("notesrows", "notespreview", "notesapplied"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                    )

    def test_content_audience_and_hidden_result_metadata_never_enter_the_pretty_ui(self):
        self.render_harness(
            fixture="visibilityfallback",
            serverTools="1",
            openLinks="1",
        )

    def test_flexible_command_fallback_hides_commands_paths_argv_and_raw_json(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="safefallback",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_generic_profile_shows_only_safe_counts_and_booleans(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="semanticcounts",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_hostile_raw_keys_never_become_auto_table_or_summary_labels(self):
        for fixture in ("hostileautokeys", "hostilesummarykeys"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                        exercise="copy",
                    )

    def test_curated_profile_final_gate_hides_credentials_paths_and_commands(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="curatedsafety",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_known_secret_values_under_benign_curated_fields_stay_hidden(self):
        self.render_harness(
            fixture="curatedsafety",
            serverTools="1",
            openLinks="1",
            exercise="copy",
        )

    def test_credential_bearing_links_have_no_raw_href_or_tooltip(self):
        for open_links in ("0", "1"):
            for exercise in ("link", "copy"):
                with self.subTest(open_links=open_links, exercise=exercise):
                    self.render_harness(
                        fixture="credentiallink",
                        serverTools="1",
                        openLinks=open_links,
                        exercise=exercise,
                    )

    def test_protected_resource_links_never_reach_href_host_or_copy(self):
        for open_links in ("0", "1"):
            with self.subTest(open_links=open_links):
                self.render_harness(
                    fixture="protectedartifact",
                    serverTools="1",
                    openLinks=open_links,
                    exercise="copy",
                )

    def test_artifacts_and_background_tasks_use_pretty_non_json_states(self):
        for fixture in ("artifact", "task"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                    )

    def test_empty_results_render_the_friendly_empty_state(self):
        # [] and {"items": []} — the ordinary answers on a quiet day, both of
        # which used to fall through to the raw key/value tree.
        for fixture in ("emptyreminders", "emptywrapped", "emptyhabits"):
            for theme in ("light", "dark"):
                with self.subTest(fixture=fixture, theme=theme):
                    self.render_harness(
                        fixture=fixture,
                        theme=theme,
                        serverTools="1",
                        openLinks="1",
                    )

    def test_output_clipped_mid_json_is_explained_not_pasted(self):
        self.render_harness(
            fixture="truncatedjson",
            serverTools="1",
            openLinks="1",
        )

    def test_generic_terminal_text_is_replaced_by_the_safe_summary(self):
        for fixture in ("terminal", "truncated"):
            with self.subTest(fixture=fixture):
                self.render_harness(
                    fixture=fixture,
                    serverTools="1",
                    openLinks="1",
                )

    def test_multimodal_content_uses_labeled_attachments_without_exposing_payload_data(self):
        for theme in ("light", "dark"):
            with self.subTest(theme=theme):
                self.render_harness(
                    fixture="multimodal",
                    theme=theme,
                    serverTools="1",
                    openLinks="1",
                )

    def test_teardown_is_acknowledged(self):
        self.render_harness(
            fixture="table",
            serverTools="1",
            openLinks="1",
            exercise="teardown",
        )


if __name__ == "__main__":
    unittest.main()
