import SwiftData
import SwiftUI

struct AddTunnelWindowView: View {
    @Environment(\.modelContext) private var modelContext

    let processManager: TunnelProcessManager

    var body: some View {
        AddTunnelView { tunnel in
            modelContext.insert(tunnel)
            do {
                try modelContext.save()
                if tunnel.startsAutomatically {
                    processManager.start(tunnel)
                }
            } catch {
                modelContext.rollback()
            }
        }
    }
}
