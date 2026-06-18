import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: zhHansBundle ?? .module, value: key, comment: "")
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: "zh_Hans"), arguments: arguments)
    }

    private static let zhHansBundle: Bundle? = {
        for resourceName in ["zh-Hans", "zh-hans"] {
            if let path = Bundle.module.path(forResource: resourceName, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }()
}
