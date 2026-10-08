import Foundation
import WebKit

// Compile actual serialized app rules without creating a window or web view.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: check_webkit_content_rules.swift input.json result.json\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let json = try String(contentsOf: input, encoding: .utf8)
let identifier = "YingChuan-rule-check-\(UUID().uuidString)"
let started = Date()
var completed = false
var succeeded = false
WKContentRuleListStore.default().compileContentRuleList(
    forIdentifier: identifier,
    encodedContentRuleList: json
) { list, error in
    succeeded = list != nil && error == nil
    let result: [String: Any] = [
        "compiler": "WKContentRuleListStore.compileContentRuleList",
        "success": succeeded,
        "error": error?.localizedDescription ?? NSNull(),
        "elapsedSeconds": Date().timeIntervalSince(started),
        "input": input.path,
        "uiCreated": false,
    ]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: output)
    print(String(data: data, encoding: .utf8)!)
    if list != nil {
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
            completed = true
        }
    } else {
        completed = true
    }
}
while !completed && Date().timeIntervalSince(started) < 15 {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}
if !completed {
    fputs("WebKit compiler did not finish within 15 seconds\n", stderr)
    exit(3)
}
exit(succeeded ? 0 : 1)
