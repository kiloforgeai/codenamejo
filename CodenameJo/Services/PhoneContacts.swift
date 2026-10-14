import AppIntents
import Contacts
import Foundation
import UIKit

/// iOS Contacts lookup for `find_contact`: a spoken name in, every match with its phone
/// numbers out, so the model can ask "which one?" and hand `send_text` a real number.
class PhoneContacts {
    struct Match: Sendable {
        /// `CNContact.identifier`, so Shortcuts can be handed the very same contact.
        let identifier: String
        let name: String
        let organization: String
        /// Label plus number, e.g. ("mobile", "+1 415-555-0100").
        let phones: [(label: String, number: String)]
        let emails: [String]

        init(identifier: String, name: String, organization: String,
             phones: [(label: String, number: String)], emails: [String] = []) {
            self.identifier = identifier
            self.name = name
            self.organization = organization
            self.phones = phones
            self.emails = emails
        }
    }

    /// The contact behind a name or number, as the object Shortcuts' Contact fields accept.
    /// Nil when nothing on the phone matches.
    @MainActor
    func person(for about: String) async throws -> IntentPerson? {
        let trimmed = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isNumber = trimmed.filter(\.isNumber).count >= 7 && !trimmed.contains("@")
        if isNumber {
            return IntentPerson(handle: .init(phoneNumber: trimmed, label: .mobile))
        }
        let outcome = await search(trimmed)
        let matches: [Match]
        switch outcome {
        case .matches(let found): matches = found
        case .denied, .needsPermission, .failed, .limited:
            throw LookupError(message: modelOutput(for: outcome, query: trimmed))
        }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else {
            throw LookupError(message: "More than one contact matches. Ask Jo again with an exact phone number.")
        }
        let match = matches[0]
        let handles = match.phones.map { IntentPerson.Handle(phoneNumber: $0.number, label: .mobile) }
            + match.emails.map { IntentPerson.Handle(emailAddress: $0) }
        return IntentPerson(
            identifier: .contact(match.identifier),
            name: .displayName(match.name),
            handle: handles.first,
            aliases: Array(handles.dropFirst()))
    }

    /// Whether Find Message got a real contact or a bare number is the whole question when a
    /// Sender filter comes back unfiltered, so log both halves.
    @available(iOS 27, *)
    func describe(_ person: IntentPerson) -> String {
        let name: String
        switch person.name {
        case .displayName(let value): name = value
        case .components(let parts): name = PersonNameComponentsFormatter().string(from: parts)
        case .unknown: name = "no name"
        @unknown default: name = "no name"
        }
        let identifier: String
        switch person.identifier {
        case .contact(let value): identifier = "contact \(value)"
        case .applicationDefined(let value): identifier = "app-defined \(value)"
        case .unknown: identifier = "NO IDENTIFIER — handle only"
        @unknown default: identifier = "NO IDENTIFIER — handle only"
        }
        let handle: String
        switch person.handle?.value {
        case .phoneNumber(let value): handle = value
        case .emailAddress(let value): handle = value
        case .applicationDefined(let value): handle = value
        case nil: handle = "no handle"
        @unknown default: handle = "no handle"
        }
        return "\(name) (\(identifier), \(handle), \(person.aliases.count) alias(es))"
    }

    enum Outcome: Sendable {
        case matches([Match])
        case denied
        case needsPermission
        case limited
        case failed(String)
    }

    struct LookupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Permission { case allowed, limited, notAsked, denied }

    var permission: Permission {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .allowed
        case .limited: return .limited
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    @MainActor
    func requestOrOpenSettings() async throws {
        switch permission {
        case .notAsked:
            _ = try await CNContactStore().requestAccess(for: .contacts)
        case .denied, .allowed, .limited:
            guard let url = URL(string: UIApplication.openSettingsURLString),
                  await UIApplication.shared.open(url) else {
                throw LookupError(message: "Jo could not open Settings. Open Settings and select Contacts access for Jo.")
            }
        }
    }

    @MainActor
    func search(_ name: String) async -> Outcome {
        await lookup(name, byPhone: false)
    }

    @MainActor
    private func lookup(_ query: String, byPhone: Bool) async -> Outcome {
        switch permission {
        case .allowed, .limited: break
        case .notAsked:
            guard UIApplication.shared.applicationState == .active else { return .needsPermission }
            do {
                guard try await CNContactStore().requestAccess(for: .contacts) else { return .denied }
            } catch {
                return .failed(error.localizedDescription)
            }
        case .denied: return .denied
        }
        let limited = permission == .limited
        guard !limited || byPhone else { return .limited }
        return await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
            let predicate = byPhone
                ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
                : CNContact.predicateForContacts(matchingName: query)
            do {
                let contacts = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
                if contacts.isEmpty, limited { return Outcome.limited }
                return Outcome.matches(contacts.map(Self.match))
            } catch {
                return Outcome.failed(error.localizedDescription)
            }
        }.value
    }

    private static func match(_ contact: CNContact) -> Match {
        Match(
            identifier: contact.identifier,
            name: CNContactFormatter.string(from: contact, style: .fullName)
                ?? [contact.givenName, contact.familyName].joined(separator: " "),
            organization: contact.organizationName,
            phones: contact.phoneNumbers.map { entry in
                let label = entry.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "phone"
                return (label, entry.value.stringValue)
            },
            emails: contact.emailAddresses.map { $0.value as String })
    }

    /// Resolve only an unambiguous number; never pick the first of several matches.
    @MainActor
    func handle(for about: String) async throws -> String {
        let trimmed = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.filter(\.isNumber).count >= 7 || trimmed.contains("@") { return trimmed }
        let outcome = await search(trimmed)
        guard case .matches(let matches) = outcome,
              matches.count == 1, matches[0].phones.count == 1 else {
            throw LookupError(message: modelOutput(for: outcome, query: trimmed))
        }
        return matches[0].phones[0].number
    }

    /// What the model reads. Says exactly how to proceed for zero, one and many matches.
    func modelOutput(for outcome: Outcome, query: String) -> String {
        switch outcome {
        case .limited:
            return "Jo can only read selected contacts, so it cannot verify that this lookup identifies one person. "
                + "Allow full Contacts access in Settings, or say the exact phone number."
        case .failed(let message):
            return "Jo could not query Contacts: \(message). Try again; this does not mean the contact is missing or access was denied."
        case .denied:
            return "Jo does not have permission to read this phone's contacts. Ask the user to allow "
                + "Contacts for Codename Jo in Settings, or to say the phone number instead."
        case .needsPermission:
            return "Jo has not been allowed to read contacts yet, and the permission prompt can only "
                + "appear while Jo is open on screen. Ask the user to open Jo and try again, or to "
                + "say the phone number."
        case .matches(let matches):
            guard !matches.isEmpty else {
                return "No contact named \"\(query)\" on this phone. Ask the user for the number or a "
                    + "different name; never guess one."
            }
            let lines = matches.map { match in
                let who = match.organization.isEmpty ? match.name : "\(match.name) (\(match.organization))"
                let phones = match.phones.map { "\($0.label) \($0.number)" }.joined(separator: ", ")
                return "- \(who): \(phones.isEmpty ? "no phone number on this contact" : phones)"
            }.joined(separator: "\n")
            let withPhones = matches.filter { !$0.phones.isEmpty }
            guard !withPhones.isEmpty else {
                return "Found \(matches.count == 1 ? "the contact" : "\(matches.count) contacts") but "
                    + "none has a phone number. Tell the user you found \(matches.map(\.name).joined(separator: ", ")) "
                    + "but there is no number to text, and ask for one:\n\(lines)"
            }
            if matches.count == 1, matches[0].phones.count == 1 {
                return "One contact with a number matches. Use this number as the recipient:\n\(lines)"
            }
            return "\(matches.count) contact(s) match, \(withPhones.reduce(0) { $0 + $1.phones.count }) number(s) "
                + "in total. Ask the user which one they mean, saying the names (and organisation or "
                + "label if that is what tells them apart), then use that exact number as the recipient:\n\(lines)"
        }
    }
}
