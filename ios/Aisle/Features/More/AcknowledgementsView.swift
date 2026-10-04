import SwiftUI

/// Credits and licenses for what Aisle is built with.
struct AcknowledgementsView: View {
    private struct Credit: Identifiable {
        let name: String
        let by: String
        let license: String
        let url: URL?
        var id: String { name }
    }

    private static let credits: [Credit] = [
        Credit(name: "Geist", by: "Vercel", license: "SIL Open Font License 1.1",
               url: URL(string: "https://github.com/vercel/geist-font")),
        Credit(name: "Fluent Emoji", by: "Microsoft", license: "MIT License · item pictures",
               url: URL(string: "https://github.com/microsoft/fluentui-emoji")),
        Credit(name: "SF Symbols", by: "Apple", license: "Used under Apple's license for apps on its platforms",
               url: URL(string: "https://developer.apple.com/sf-symbols/")),
        Credit(name: "Store logos", by: "logo.dev", license: "Logos belong to their owners",
               url: URL(string: "https://logo.dev")),
    ]

    var body: some View {
        MoreScreen(title: "Acknowledgements") {
            Text("Aisle is built with help from these. Thank you.")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 4)

            MoreCard(padding: 0) {
                ForEach(Array(Self.credits.enumerated()), id: \.element.id) { index, credit in
                    if index > 0 {
                        Divider().overlay(Theme.hairline).padding(.leading, 16)
                    }
                    row(credit)
                }
            }
            .padding(.top, 20)

            MoreSectionTitle(text: "Fluent Emoji license")
            Text(Self.mitLicense)
                .font(Theme.font(12, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            MoreSectionTitle(text: "Store maps")
            Text("Aisle locations come from store layouts, shopper reports and AI estimates. Estimates are labeled; Aisle never makes up an aisle number. Store names and logos are trademarks of their owners and don't imply endorsement.")
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let mitLicense = """
    MIT License

    Copyright (c) Microsoft Corporation.

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    @ViewBuilder
    private func row(_ credit: Credit) -> some View {
        let content = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.name)
                    .font(Theme.font(16, .semibold, relativeTo: .body))
                    .foregroundStyle(Theme.ink)
                Text("\(credit.by) · \(credit.license)")
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if credit.url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        if let url = credit.url {
            Link(destination: url) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}
