#!/usr/bin/env python3
"""Query the Microsoft Learn MCP server from the command line.

The Microsoft Learn MCP server (https://learn.microsoft.com/api/mcp) serves
official Microsoft Graph / Entra ID / Azure documentation. This script talks
the MCP streamable-HTTP protocol directly, so that documentation is reachable
from any shell, without an MCP client or editor in the loop.

The endpoint is unauthenticated: no OAuth, no API key, no token.

Usage:
  scripts/learn-search.py "signInActivity lastSignInDateTime permissions"
  scripts/learn-search.py --code "list users with signInActivity" --language powershell
  scripts/learn-search.py --fetch https://learn.microsoft.com/graph/api/user-list

Options:
  --fetch URL         Fetch one Learn page and print it as markdown.
  --code              Search code samples instead of prose documentation.
  --language LANG     Language hint for --code (csharp, powershell, python, ...).
  --max N             Show at most N results (default 5, 0 for all).
  --chars N           Truncate each result body to N chars (default 1500, 0 for full).
  --json              Emit the raw tool payload instead of formatted text.

Exit codes: 0 ok, 1 no results, 2 usage error, 3 transport/protocol error.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://learn.microsoft.com/api/mcp"
PROTOCOL_VERSION = "2025-06-18"
TIMEOUT = 60

LANGUAGES = (
    "csharp javascript typescript python powershell azurecli al sql "
    "java kusto cpp go rust ruby php"
).split()


class McpError(RuntimeError):
    """Transport-, HTTP- or JSON-RPC-level failure talking to the server."""


class Client:
    """Minimal MCP streamable-HTTP client: initialize, then call tools."""

    def __init__(self, endpoint=ENDPOINT):
        self.endpoint = endpoint
        self.session_id = None
        self._next_id = 0

    def _post(self, method, params, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            self._next_id += 1
            body["id"] = self._next_id

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL_VERSION,
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id

        request = urllib.request.Request(
            self.endpoint, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                session_id = response.headers.get("Mcp-Session-Id")
                if session_id:
                    self.session_id = session_id
                raw = response.read().decode()
        except urllib.error.HTTPError as exc:
            raise McpError(f"{method}: HTTP {exc.code} {exc.reason}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            # Typically a blocked egress proxy or DNS failure.
            raise McpError(f"{method}: cannot reach {self.endpoint} ({exc})") from exc

        if notify:
            return None

        message = _parse_body(raw)
        if message is None:
            raise McpError(f"{method}: empty response body")
        if "error" in message:
            error = message["error"]
            raise McpError(f"{method}: JSON-RPC {error.get('code')} {error.get('message')}")
        return message.get("result", {})

    def connect(self):
        result = self._post(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "learn-search", "version": "1.0"},
            },
        )
        self._post("notifications/initialized", {}, notify=True)
        return result.get("serverInfo", {})

    def call_tool(self, name, arguments):
        result = self._post("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise McpError(f"{name} reported an error: {_text_of(result)[:400]}")
        return result


def _parse_body(raw):
    """Decode a response that may be plain JSON or an SSE event stream."""
    payloads = [
        line[len("data:"):].strip()
        for line in raw.splitlines()
        if line.startswith("data:")
    ]
    for payload in reversed(payloads):
        if payload and payload != "[DONE]":
            return json.loads(payload)
    return json.loads(raw) if raw.strip() else None


def _text_of(result):
    """Concatenate the text blocks of a tools/call result."""
    return "\n".join(
        block.get("text", "")
        for block in result.get("content", [])
        if block.get("type", "text") == "text"
    )


def _clip(text, limit):
    text = text.strip()
    if limit and len(text) > limit:
        return text[:limit].rstrip() + "\n  […truncated, rerun with --chars 0 for the full text]"
    return text


def _indent(text, prefix="  "):
    return "\n".join(prefix + line for line in text.splitlines())


def _summarize(result):
    """Pull (title, url, body) out of a result.

    Prose hits carry title/content/contentUrl; code-sample hits carry
    description/codeSnippet/link instead.
    """
    # Code-sample descriptions arrive as "key: value" lines; the first one is
    # the human-readable summary and makes a better title than the snippet.
    description = ""
    for line in (result.get("description") or "").splitlines():
        if line.strip():
            description = line.split(":", 1)[-1].strip() if ":" in line else line.strip()
            break

    title = result.get("title") or description
    url = result.get("contentUrl") or result.get("url") or result.get("link")

    body = result.get("content") or ""
    snippet = result.get("codeSnippet")
    if snippet:
        body = f"```{result.get('language', '')}\n{snippet.strip()}\n```"

    return title or "(untitled)", url or "(no source URL)", body


def print_results(payload, max_results, chars):
    """Render a search payload. Returns the number of results shown."""
    try:
        results = json.loads(payload).get("results", [])
    except (json.JSONDecodeError, AttributeError):
        # Not the documented {"results": [...]} envelope - show it verbatim.
        print(_clip(payload, chars))
        return 1 if payload.strip() else 0

    if max_results:
        results = results[:max_results]

    for index, result in enumerate(results, start=1):
        title, url, body = _summarize(result)
        print(f"\n[{index}] {title}")
        print(f"    source: {url}")
        if body:
            print(_indent(_clip(body, chars), "    "))
    return len(results)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="learn-search.py",
        description="Search or fetch official Microsoft Learn documentation via MCP.",
    )
    parser.add_argument("query", nargs="?", help="what to search for")
    parser.add_argument("--fetch", metavar="URL", help="fetch a Learn page as markdown")
    parser.add_argument("--code", action="store_true", help="search code samples")
    parser.add_argument("--language", help=f"language hint for --code ({', '.join(LANGUAGES)})")
    parser.add_argument("--max", type=int, default=5, metavar="N", help="max results (0 = all)")
    parser.add_argument("--chars", type=int, default=1500, metavar="N",
                        help="truncate each body (0 = full)")
    parser.add_argument("--json", action="store_true", help="print the raw tool payload")
    args = parser.parse_args(argv)

    if bool(args.fetch) == bool(args.query):
        parser.error("give either a query or --fetch URL, not both or neither")
    if args.fetch and args.code:
        parser.error("--fetch and --code are mutually exclusive")
    if args.language and not args.code:
        parser.error("--language only applies with --code")
    if args.language and args.language not in LANGUAGES:
        parser.error(f"--language must be one of: {', '.join(LANGUAGES)}")
    return args


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    client = Client()

    try:
        server = client.connect()
        if args.fetch:
            tool, arguments = "microsoft_docs_fetch", {"url": args.fetch}
        elif args.code:
            tool = "microsoft_code_sample_search"
            arguments = {"query": args.query}
            if args.language:
                arguments["language"] = args.language
        else:
            tool, arguments = "microsoft_docs_search", {"query": args.query}
        result = client.call_tool(tool, arguments)
    except McpError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3

    payload = _text_of(result)
    name = server.get("name", "Microsoft Learn MCP Server")
    print(f"# {name} · {tool} · {args.fetch or args.query}", file=sys.stderr)

    if args.json:
        print(payload)
        return 0 if payload.strip() else 1

    if args.fetch:
        print(_clip(payload, args.chars))
        if payload.strip():
            print(f"\nsource: {args.fetch}")
            return 0
        print("no content returned", file=sys.stderr)
        return 1

    if print_results(payload, args.max, args.chars):
        return 0
    print("no results", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
