//
//  AddressFormatter.swift
//  SecureScan
//
//  Formats reverse-geocoded parts as "30 Sample Cr, Testwood, WA".
//  Foundation only - unit tested.
//

import Foundation

enum AddressFormatter {

    /// Australian street-type abbreviations (last word of the street name).
    static let streetTypes: [String: String] = [
        "street": "St", "road": "Rd", "avenue": "Ave", "crescent": "Cr", "drive": "Dr",
        "court": "Ct", "place": "Pl", "close": "Cl", "parade": "Pde", "terrace": "Tce",
        "boulevard": "Bvd", "lane": "Ln", "highway": "Hwy", "circuit": "Cct", "grove": "Gr",
        "square": "Sq", "esplanade": "Esp", "gardens": "Gdns", "heights": "Hts",
        "retreat": "Rtt", "rise": "Rise", "way": "Way", "loop": "Loop", "mews": "Mews",
    ]

    static let states: [String: String] = [
        "western australia": "WA", "new south wales": "NSW", "victoria": "VIC",
        "queensland": "QLD", "south australia": "SA", "tasmania": "TAS",
        "northern territory": "NT", "australian capital territory": "ACT",
    ]

    static func abbreviateStreet(_ street: String) -> String {
        var words = street.split(separator: " ").map(String.init)
        guard let last = words.last, let abbr = streetTypes[last.lowercased()] else { return street }
        words[words.count - 1] = abbr
        return words.joined(separator: " ")
    }

    static func abbreviateState(_ state: String) -> String {
        let t = state.trimmingCharacters(in: .whitespaces)
        if let abbr = states[t.lowercased()] { return abbr }
        return t.count <= 3 ? t.uppercased() : t
    }

    static func format(number: String?, street: String?, suburb: String?, state: String?) -> String {
        let clean: (String?) -> String = { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let line1 = [clean(number), abbreviateStreet(clean(street))].filter { !$0.isEmpty }.joined(separator: " ")
        let st = clean(state)
        let parts = [line1, clean(suburb), st.isEmpty ? "" : abbreviateState(st)]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
