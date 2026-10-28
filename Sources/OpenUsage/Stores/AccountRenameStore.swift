import Foundation
import Observation

@MainActor
@Observable
final class AccountRenameStore {
    struct Edit: Equatable {
        let providerID: String
        fileprivate let serial: Int
    }

    private(set) var edit: Edit?
    var draft = ""
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let accounts: AccountStore

    init(accounts: AccountStore) {
        self.accounts = accounts
    }

    func begin(_ providerID: String) {
        guard let account = accounts.account(cardID: providerID) else { return }
        commit()
        serial += 1
        edit = Edit(providerID: providerID, serial: serial)
        draft = account.label
    }

    func commit(_ edit: Edit? = nil) {
        guard let open = close(edit) else { return }
        let label = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let account = accounts.account(cardID: open.providerID),
              account.label != label else { return }
        accounts.rename(account.id, to: label)
    }

    func cancel(_ edit: Edit? = nil) {
        close(edit)
    }

    @discardableResult
    private func close(_ edit: Edit?) -> Edit? {
        guard let open = self.edit, edit == nil || edit == open else { return nil }
        self.edit = nil
        return open
    }
}
