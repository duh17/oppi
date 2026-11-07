#if DEBUG
import Foundation

/// `CHAT_ROUTES_SURFACE=jobs`: the Background jobs surface as the server renders it
/// (`server/plugins/background-jobs`) for two running jobs: a short command (`ls`) with no output
/// yet, whose title is narrower than its caption, then one whose output tail is long, so the card
/// is taller than a drawer's cap and the output block is the part that overflows.
/// `__STARTED__` is the job's start time, stamped when the surface is seeded.
enum ChatRoutesJobsSurface {
    static var json: String {
        let startedAt = Int(Date().timeIntervalSince1970 * 1000) - 104_000
        return template.replacingOccurrences(of: "__STARTED__", with: String(startedAt))
    }

    private static let template = #"""
{
  "version": 2,
  "id": "background-jobs",
  "title": "Background jobs",
  "placement": {
    "kind": "strip"
  },
  "lifecycle": "persistent",
  "header": {
    "title": "Background jobs",
    "subtitle": "2 running"
  },
  "pill": {
    "content": {
      "type": "row",
      "children": [
        {
          "id": "pill:count",
          "type": "text",
          "text": "1 job running",
          "style": "headline"
        },
        {
          "id": "pill:elapsed",
          "type": "elapsed",
          "since": __STARTED__,
          "style": "caption",
          "format": "short"
        },
        {
          "id": "pill:line",
          "type": "text",
          "text": "Waiting for the screenshot run to finish",
          "style": "caption"
        }
      ]
    },
    "tap": "drawer"
  },
  "sections": [
    {
      "composite": "blocks",
      "id": "jobs",
      "state": {
        "kind": "content"
      },
      "fallback": {
        "text": "│ ⚙ 1 job · 1m\n│ ● bash-72 [running] · 1m · while [ \"$(sysctl -n vm.loadavg)\" ]; do sleep 5; done\n│   Waiting for the screenshot run to finish\n│ [ctrl+o: expand · +10 lines]"
      },
      "body": {
        "id": "list",
        "type": "stack",
        "children": [
          {
            "id": "job:bash-8",
            "type": "stack",
            "children": [
              {
                "id": "head:bash-8",
                "type": "row",
                "children": [
                  {
                    "id": "status:bash-8",
                    "type": "icon",
                    "name": "arrow.triangle.2.circlepath",
                    "tone": "accent"
                  },
                  {
                    "id": "title:bash-8",
                    "type": "text",
                    "text": "ls",
                    "style": "headline"
                  },
                  {
                    "id": "elapsed:bash-8",
                    "type": "elapsed",
                    "since": __STARTED__,
                    "style": "caption",
                    "format": "clock"
                  },
                  {
                    "id": "stop:bash-8",
                    "type": "button",
                    "title": "Stop",
                    "role": "destructive",
                    "action": {
                      "id": "stop",
                      "values": {
                        "job": "bash-8"
                      }
                    }
                  }
                ]
              },
              {
                "id": "meta:bash-8",
                "type": "text",
                "text": "bash-8 · Running",
                "style": "caption"
              },
              {
                "id": "detail:bash-8",
                "type": "text",
                "text": "oppi",
                "style": "caption"
              },
              {
                "id": "tail:bash-8",
                "type": "text",
                "text": "No output yet",
                "style": "caption"
              }
            ],
            "spacing": "tight"
          },
          {
            "id": "job:bash-72",
            "type": "stack",
            "children": [
              {
                "id": "rule:bash-72",
                "type": "divider"
              },
              {
                "id": "head:bash-72",
                "type": "row",
                "children": [
                  {
                    "id": "status:bash-72",
                    "type": "icon",
                    "name": "arrow.triangle.2.circlepath",
                    "tone": "accent"
                  },
                  {
                    "id": "title:bash-72",
                    "type": "text",
                    "text": "while [ \"$(sysctl -n vm…",
                    "style": "headline"
                  },
                  {
                    "id": "elapsed:bash-72",
                    "type": "elapsed",
                    "since": __STARTED__,
                    "style": "caption",
                    "format": "clock"
                  },
                  {
                    "id": "stop:bash-72",
                    "type": "button",
                    "title": "Stop",
                    "role": "destructive",
                    "action": {
                      "id": "stop",
                      "values": {
                        "job": "bash-72"
                      }
                    }
                  }
                ]
              },
              {
                "id": "meta:bash-72",
                "type": "text",
                "text": "bash-72 · Running",
                "style": "caption"
              },
              {
                "id": "detail:bash-72",
                "type": "text",
                "text": "wt_app · times out in 58m",
                "style": "caption"
              },
              {
                "id": "tail:bash-72",
                "type": "code",
                "language": "output",
                "text": "…lures (0 unexpected) in 0.089 seconds\nTest Suite 'OppiTests.xctest' passed at 2026-11-07 01:31:25.103.\n     Executed 1 test, with 0 failures (0 unexpected) in 16.095 (16.102) seconds\n     Executed 1 test, with 0 failures (0 unexpected) in 16.095 (16.104) seconds\nFull log: ~/work/app/clients/apple/.build/logs/pool-0-20261107-013123.log\nSummary: ~/work/app/clients/apple/.build/logs/pool-0-20261107-013123.summary.json\nWaiting for the screenshot run to finish"
              },
              {
                "id": "output:bash-72",
                "type": "group",
                "title": "Details",
                "collapsed": true,
                "children": [
                  {
                    "id": "command:bash-72",
                    "type": "text",
                    "text": "while [ \"$(sysctl -n vm.loadavg)\" ]; do sleep 5; done",
                    "style": "mono"
                  },
                  {
                    "id": "cwd:bash-72",
                    "type": "text",
                    "text": "~/work/wt_app",
                    "style": "mono"
                  }
                ]
              }
            ],
            "spacing": "tight"
          }
        ]
      }
    }
  ],
  "actions": {
    "stop": {
      "title": "Stop",
      "role": "destructive",
      "pending": {
        "title": "Stopping…"
      }
    }
  },
  "fallback": {
    "text": "│ ⚙ 1 job · 1m\n│ ● bash-72 [running] · 1m · while [ \"$(sysctl -n vm.loadavg)\" ]; do sleep 5; done\n│   Waiting for the screenshot run to finish\n│ [ctrl+o: expand · +10 lines]"
  },
  "revision": 1
}
"""#
}
#endif
