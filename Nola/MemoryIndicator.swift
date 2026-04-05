import MLX
import SwiftUI

struct MemoryIndicator: View {
    @Environment(MLXService.self) private var mlxService

    var body: some View {
        if mlxService.isReady {
            let usedBytes = Memory.activeMemory + Memory.cacheMemory
            let usedGB = Double(usedBytes) / 1_073_741_824

            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.1f GB", usedGB))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
