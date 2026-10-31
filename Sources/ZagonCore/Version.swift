// .github/workflows/release.yml writes the tag's version here (v0.1.0 -> 0.1.0) before it builds.
// `zagon --version`, `export` and the MCP `serverInfo` all read it.
public let zagonVersion = "dev"
