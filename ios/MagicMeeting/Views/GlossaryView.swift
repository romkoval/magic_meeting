import SwiftData
import SwiftUI

struct GlossaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GlossaryTerm.createdAt, order: .reverse) private var terms: [GlossaryTerm]
    @State private var input = ""
    @State private var saveFailed = false

    private var parsed: [String] {
        GlossaryInput.parse(input, existing: terms.map(\.term))
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Surname or term", text: $input, axis: .vertical)
                        // Autocorrect would "fix" exactly the names the glossary exists for.
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .buttonStyle(.borderless)
                        .disabled(parsed.isEmpty)
                }
            } footer: {
                Text("Names and terms help recognize speech correctly. Separate several with commas or new lines.")
            }

            if terms.isEmpty {
                Section {
                    ContentUnavailableView("No terms yet", systemImage: "character.book.closed")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(terms) { term in
                        Text(term.term)
                    }
                    .onDelete { delete($0) }
                } footer: {
                    usageFooter
                }
            }
        }
        .navigationTitle("Glossary")
        .onChange(of: input) { old, new in
            // A vertical field types a new line on Return instead of submitting; pasted
            // lists keep theirs and are split by the parser.
            if new == old + "\n" {
                input = old
                add()
            }
        }
        .alert("Couldn't save the glossary.", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var usageFooter: some View {
        let usage = GlossaryInput.whisperUsage(terms.map(\.term))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recognition uses \(usage.used) of \(GlossaryInput.whisperBudget) characters")
            if usage.included < terms.count {
                Text("Only the newest \(usage.included) terms fit into recognition; all are used for summaries and edits.")
            }
        }
    }

    private func add() {
        let newTerms = parsed
        guard !newTerms.isEmpty else { return }
        let now = Date.now
        for (index, term) in newTerms.enumerated() {
            // Distinct times keep a pasted list in its own order at the top of the list.
            let createdAt = now.addingTimeInterval(-Double(index) / 1_000)
            modelContext.insert(GlossaryTerm(term: term, createdAt: createdAt))
        }
        if save() {
            input = ""
        }
    }

    private func delete(_ offsets: IndexSet) {
        for term in offsets.map({ terms[$0] }) {
            modelContext.delete(term)
        }
        save()
    }

    /// On failure the context goes back to its last saved state, so the list never shows
    /// terms that would be lost on the next launch. The typed text stays for another try.
    @discardableResult
    private func save() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            saveFailed = true
            return false
        }
    }
}
