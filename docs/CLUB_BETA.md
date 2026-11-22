# MacRemote 1.1.3 Club Beta

MacRemote lets an MCP app use command-line tools on your Mac. You choose which
tools to share. MacRemote asks before an app connects, and risky tools can ask
again before they run.

You need macOS 26 or later. You do not need Xcode, Swift, Homebrew, Wrangler, or
a Cloudflare account for the fastest setup.

## Download and open MacRemote

Download `MacRemote-1.1.3.zip` from the MacStories Club post.

1. Double-click `MacRemote-1.1.3.zip`. A folder named **MacRemote 1.1.3** appears
   next to it.
2. Open that folder and drag **MacRemote** into your Applications folder.
3. Open the Applications folder and double-click **MacRemote**.
4. macOS asks whether you want to open an app downloaded from the internet.
   Choose **Open**.

MacRemote 1.1.3 is signed with a Developer ID and notarized by Apple, so it opens
like any other app you download. You do not need **Open Anyway**.

The folder also holds this guide, the [release
notes](releases/1.1.3.md), and a **Source** folder with MacRemote's source code.
You only need the app.

If you use an earlier MacRemote, quit it first and replace the old copy in
Applications. Your tools, connected apps, and settings carry over. [What's new
in 1.1.3](releases/1.1.3.md) lists what changed.

### Optional: check the app

macOS checks the signature and Apple's notarization when you first open the
app. To see the result yourself, open Terminal after step 2 and run:

```bash
spctl -a -vv /Applications/MacRemote.app
```

The answer should say `accepted`, `source=Notarized Developer ID`, and
`origin=Developer ID Application: Federico Viticci (4W35M4UN6R)`. If it does
not, delete the app and the ZIP and download them again.

## Choose at least one tool

MacRemote shows tools that are available on your Mac. A command-line app that
is not installed simply does not appear. That is normal.

1. In Welcome, select **Current Date** and deselect any other selected bundles
   for the simplest first test. It is a safe read-only starter built into macOS.
   You can instead choose a small available bundle that contains tools you
   recognize.
2. Choose **Add 1 Tool**. If you selected a bundle, the button shows its tool
   count instead.
3. Continue to **Start the connection**. You can review or change sharing later
   in **Tools**; share only tools that you want the connected app to use.

Current Date is optional; MacRemote never adds it unless you select it. If you
skip the tool step, open **Tools**, choose **Add from Library**, add an available
tool, and turn on **Share** for it before starting the connection.

## Install Cloudflare's helper

MacRemote uses Cloudflare's helper to create either kind of public link. The
app can install and verify its own copy. You do not need Homebrew.

1. In Welcome, continue to **Start the connection**. You can also open
   **Connection** and expand **Address**.
2. If you see the one-time helper setup, open **What gets installed** and review
   the download details.
3. Choose **Install Helper**.
4. Wait until MacRemote says **Cloudflare's helper is ready**. The ready message
   appears briefly; setup is also complete when that helper row disappears.

Now choose one of the two setups below.

## Option 1: Instant Link

Choose Instant Link when you want the fastest setup.

- It creates a random, temporary address.
- It needs no Cloudflare account, domain, API token, Homebrew, or Wrangler.
- Its address changes each time you start a new Instant Link.

1. Choose **Instant Link**.
2. Choose **Start Instant Link**. MacRemote starts its local server first when
   needed.
3. Wait for the public link to appear.
4. Copy the address. It ends in `/mcp`.
5. Continue to [Connect your MCP app](#connect-your-mcp-app).

Keep MacRemote open while you use the link. If you stop sharing, quit
MacRemote, or start a new Instant Link, update the saved address in your MCP
app.

## Option 2: Your Domain

Choose Your Domain when you want a stable address such as
`macremote.example.com`.

Before you start, you need:

- a Cloudflare account;
- a domain you own that is active in that account; and
- a Cloudflare API token scoped to that account and domain.

Create a custom user token from **Cloudflare dashboard → My Profile → API
Tokens → Create Token → Create Custom Token**. Cloudflare administrators may
instead create an account-owned token under **Manage Account → API Tokens**.
The user-token path is simpler for this beta. Cloudflare documents both in its
current [API-token guide](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/).

Give the token these permissions:

- **Account → Cloudflare Tunnel → Edit**
- **Zone → Zone → Read**
- **Zone → DNS → Edit**
- **Zone → Config Rules → Edit**

Limit **Account Resources** to the account that owns the domain. Limit **Zone
Resources** to the one domain MacRemote will use. Save the token in your
password manager. Treat it as a password and never paste it into a message,
log, screenshot, or issue.

Then set up the link in this exact order:

1. In Welcome, choose **Your Domain**, then choose **Set Up Your Domain**. You
   can also open **Connection**, expand **Address**, and choose **Your Domain**.
2. Paste the API token into MacRemote.
3. Choose **Load Domains**.
4. Choose your domain.
5. Enter a subdomain, such as `macremote`.
6. Choose **Deploy Your Domain**.
7. Wait for the public link to appear, then copy the address ending in `/mcp`.
8. Continue to [Connect your MCP app](#connect-your-mcp-app).

MacRemote keeps the API token in memory only. It does not save it. Quitting
MacRemote stops the public link, but the hostname and MacRemote-owned
Cloudflare resources remain in your Cloudflare account. To bring the same
hostname online again, reopen MacRemote, paste the token, load the domains,
choose the same domain and subdomain, and deploy again.

## Connect your MCP app

Leave the sign-in method on **Dynamic OAuth**, the default. Most people do not
need the advanced sign-in methods.

1. In MacRemote's **Connect your app** screen, choose the app you use and follow
   the instructions shown for it.
2. Paste the public `/mcp` address into the app when it asks for a remote MCP
   server.
3. The app opens a MacRemote sign-in page in your browser. The page shows a
   six-digit code.
4. Return to MacRemote and find the connection request in **Connect your app**.
   If you already closed Welcome, open **Requests**.
5. Compare the code in MacRemote with the code on your sign-in page. Approve
   only when they match. If you did not start a sign-in, choose **Deny**:
   anyone who knows your public address can ask to connect under any name.
6. In the MCP app, try a harmless read-only tool first.

A sign-in request expires after 5 minutes. If it expires, start the connection
again in the MCP app.

Two app-specific notes:

- **Claude.** In **Add custom connector**, keep **Sign in now**. Under **OAuth
  client**, **Use Claude's published identity** and **Register automatically**
  both work.
- **ChatGPT.** Its **Add custom MCP server** form has an optional **Icon**
  field that takes a PNG of 10 KB or less. To use MacRemote's icon, open your
  public address with `/macremote-icon-256.png` in place of `/mcp`, save the
  image, and choose it there.

An app's own confirmation and a MacRemote approval are separate. A tool that
can change something asks for another approval before it runs. The request
shows everything the tool will receive. A notification banner can deny a
request but cannot approve one; open MacRemote to approve.

Keep MacRemote open while the MCP app is connected. The local server and the
public link stop when MacRemote quits.

## Troubleshooting

### No tools appear

Missing command-line apps are normal. Open **Tools**, choose **Add from
Library**, and add a tool that is available on your Mac. Confirm that at least
one tool has **Share** turned on.

### The Instant Link button is unavailable

Confirm that at least one tool is shared. Then return to **Connection →
Address**. If Cloudflare's helper is missing, choose **Install Helper** and wait
for the ready message.

### Cloudflare's helper does not become ready

Choose **Try Again** after a failed install, or choose **Check Again** if you
already installed it. You can also review its status in **Settings → General →
Cloudflare Helper**. MacRemote discards a download that does not match its
published checksum or signature.

### Load Domains is unavailable

**Load Domains** becomes available when you paste a Cloudflare API token or when
Wrangler is installed and signed in on this Mac. Paste the token, or install
Wrangler and sign in, then choose **Load Domains** again. Confirm that the domain
is active in that account. Deployment still requires the pasted API token.

### Cloudflare rejects the API token

Check all four permissions and both resource scopes listed above. If the token
was copied incorrectly or exposed, revoke it, create a replacement, and save
the replacement in your password manager.

### The MCP app does not connect

Confirm that MacRemote is still open and the public link is still visible.
Confirm that the address pasted into the app ends in `/mcp`, and leave
MacRemote's sign-in method on **Dynamic OAuth**. Look in **Requests** for a
connection waiting for approval. A request that waited more than 5 minutes has
expired; start the connection again in the MCP app.

If the browser says the sign-in can't start, MacRemote refused the request.
Open **Activity** to see why, then remove MacRemote in the MCP app and add it
again.

### File Transfer cannot reach a file

The built-in File Transfer tools reach only Desktop, Documents, and Downloads
until you add more folders in **Settings → Security → File Transfer Folders**.
To let apps you trust reach every file, choose **Allow Whole Mac…** there.

### macOS still will not open the app

Confirm that `MacRemote.app` is in Applications and double-click it once. Then
open **System Settings → Privacy & Security** and choose **Open Anyway** for
MacRemote. Do not disable Gatekeeper. If Open Anyway does not appear or the same
message returns, download a fresh copy from the Club post and report the exact
macOS message to the beta team.
