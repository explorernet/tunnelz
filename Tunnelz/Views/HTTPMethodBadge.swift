import SwiftUI

struct HTTPMethodBadge: View {
    let method: String

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 52, height: 16)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch method.uppercased() {
        case "GET": .blue
        case "POST": .green
        case "PUT": .purple
        case "PATCH": .orange
        case "DELETE": .red
        case "HEAD": .cyan
        case "OPTIONS": .indigo
        default: .secondary
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(["POST", "DELETE", "PATCH", "GET", "PUT"], id: \.self) {
            HTTPMethodBadge(method: $0)
        }
    }
    .padding()
}
