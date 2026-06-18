import Foundation

enum CoreL10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: zhHansBundle ?? .module, value: key, comment: "")
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: "zh_Hans"), arguments: arguments)
    }

    private static let zhHansBundle: Bundle? = {
        guard let path = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()
}
