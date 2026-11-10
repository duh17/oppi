/**
 * What a `name` tag value may look like: the allowed characters and the rules
 * that store a location-shaped value as `unknown`. Pure data, shared by the
 * catalog's tag vocabulary, server validation (`validate.ts`), and the Swift
 * generator, so both sides apply exactly the same ones.
 */

/**
 * Characters a `name` tag value may use besides ASCII letters and digits.
 * `:` and `@` keep HTTP route patterns (`/workspaces/:workspaceId`) and
 * versioned model ids (`claude-opus-4@20250514`, `qwen3:32b`). `-` stays last
 * so the string drops into a regex character class as is.
 */
export const NAME_TAG_PUNCTUATION = "._/:@-";
export const NAME_TAG_MAX_LENGTH = 128;
export const NAME_TAG_PATTERN = new RegExp(
  `^[A-Za-z0-9${NAME_TAG_PUNCTUATION}]{1,${NAME_TAG_MAX_LENGTH}}$`,
);
export const NAME_TAG_FALLBACK = "unknown";

/**
 * One reason a `name` value is stored as `unknown` although its characters are
 * allowed: it looks like a location (URL, host, address, path) rather than an
 * identifier. The rules are data so the server (`validate.ts`) and the
 * generated Swift (`TelemetryName`) apply exactly the same ones: `source` is a
 * regular expression in the syntax JavaScript and ICU share (no lookbehind, no
 * inline flags). The check is defence in depth: a bare or public hostname
 * (`stt-box`, `example.com`) or a relative path is indistinguishable from an
 * identifier, so a source of `name` tags must still be bounded to constants or
 * enum-like values.
 */
export interface NameLocationRule {
  readonly id: string;
  readonly source: string;
  readonly ignoreCase?: true;
  /** A route template (`route` tags) may match this rule, as `/workspaces/:workspaceId` does. */
  readonly exemptForRoute?: true;
  /**
   * A cheap prefilter: the rule can only match a value that contains at least
   * one of these substrings (compared ignoring ASCII case; a single character
   * must not be a letter). Both sides skip the regex when none is present, which
   * is what keeps sanitizing a plain `bash` or `chat` free of regex work. The
   * server tests check every rule against the shared fixture and a fuzz sweep.
   */
  readonly needs: readonly string[];
  readonly description: string;
}

export const NAME_LOCATION_RULES: readonly NameLocationRule[] = [
  { id: "url_scheme", needs: [":"], source: "://", description: "A URL (`https://host`)." },
  {
    id: "home_path",
    needs: ["~"],
    source: "^~",
    description: "A home-relative path (`~/models`).",
  },
  {
    id: "absolute_path",
    needs: ["/"],
    source: "^/",
    exemptForRoute: true,
    description: "An absolute path (`/Users/me/models`); a route template may start with `/`.",
  },
  {
    id: "localhost",
    needs: ["localhost"],
    source: "(^|[^A-Za-z0-9])localhost($|[^A-Za-z0-9])",
    ignoreCase: true,
    description: "`localhost` as a whole word.",
  },
  {
    id: "private_host_suffix",
    needs: ["."],
    source: "\\.(local|lan|internal|localdomain|ts\\.net|home\\.arpa)$",
    ignoreCase: true,
    description: "A private or tailnet host name (`mac-studio.tail1234.ts.net`).",
  },
  {
    id: "ipv4",
    needs: ["."],
    source: "^\\d{1,3}(\\.\\d{1,3}){3}(:\\d+)?$",
    description: "An IPv4 address, with an optional port.",
  },
  {
    id: "ipv6",
    needs: [":"],
    source: "^(?=([^:]*:){2})[0-9A-Fa-f:.]+$",
    description:
      "An IPv6 address (`fd7a:115c:a1e0::53`, `::1`): two or more colons, hex digits only.",
  },
  {
    id: "host_port",
    needs: [":"],
    source: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}:\\d{2,5}$",
    description: "A host with an alphabetic top-level domain and a port (`stt.example.com:7936`).",
  },
  {
    id: "user_at_host",
    needs: ["@"],
    source: "^[^@]+@[^@]*\\.[A-Za-z]{2,}$",
    description: "`user@host.tld`; a leading `@` scope (`@cf/meta/llama`) has no user.",
  },
];
