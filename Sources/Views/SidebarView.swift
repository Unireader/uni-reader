import SwiftUI
import SwiftData

struct SidebarView: View {
    var documents: [Document]
    var groups: [LibraryGroup]
    @Binding var selection: Document?

    var body: some View {
        List(selection: $selection) {
            Section(L("Recent")) {
                ForEach(documents) { doc in
                    row(doc).tag(doc)
                }
            }
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.documents) { doc in
                        row(doc).tag(doc)
                    }
                }
            }
        }
        .navigationTitle(L("Library"))
    }

    private func row(_ doc: Document) -> some View {
        Label(doc.title, systemImage: "doc.richtext")
    }
}
