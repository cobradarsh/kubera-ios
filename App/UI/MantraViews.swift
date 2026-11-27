import SwiftUI

/// Salutations to Sri Venkateshwara, Goddess Mahalakshmi and Kubera, and the Kubera mantra for prosperity.
enum Mantra {
    struct Salutation: Identifiable {
        var id: String { latin }
        var devanagari: String
        var latin: String
        var deity: String
    }

    static let salutations: [Salutation] = [
        Salutation(devanagari: "ॐ नमो वेङ्कटेशाय", latin: "Om Namo Venkateshaya", deity: "Sri Venkateshwara"),
        Salutation(devanagari: "ॐ श्रीं महालक्ष्म्यै नमः", latin: "Om Shreem Mahalakshmyai Namah", deity: "Goddess Lakshmi"),
        Salutation(devanagari: "ॐ कुबेराय नमः", latin: "Om Kuberaya Namah", deity: "Sri Kubera"),
    ]

    /// The 35-syllable Kubera mantra (Kubera Panchatrinsha); rishi Vishrava, metre Brihati.
    static let kuberaDevanagari = "ॐ यक्षाय कुबेराय वैश्रवणाय\nधनधान्याधिपतये\nधनधान्यसमृद्धिं मे देहि दापय स्वाहा ॥"
    static let kuberaLatin = "Om Yakshaya Kuberaya Vaishravanaya\nDhanadhanyadhipataye\nDhanadhanya Samriddhim Me Dehi Dapaya Swaha"
    static let kuberaMeaning = "Om. Salutations to Kubera, lord of the Yakshas, son of Vishrava, master of wealth and grain. Grant me abundance of wealth and grain; let it be given. Svaha."

    static let lakshmiGayatriDevanagari = "ॐ महालक्ष्म्यै च विद्महे\nविष्णुपत्न्यै च धीमहि\nतन्नो लक्ष्मीः प्रचोदयात् ॥"
    static let lakshmiGayatriLatin = "Om Mahalakshmyai cha Vidmahe\nVishnupatnyai cha Dhimahi\nTanno Lakshmih Prachodayat"
    static let lakshmiGayatriMeaning = "We meditate on Mahalakshmi, consort of Vishnu; may Lakshmi inspire and illumine us."
}

/// The band at the top of each main screen. Tap for the mantras.
struct MantraHeader: View {
    @AppStorage(Pref.mantraScript) private var script = "devanagari"
    @EnvironmentObject var router: Router

    var body: some View {
        Button { router.showMantra = true } label: {
            HStack(spacing: 0) {
                ForEach(Array(Mantra.salutations.enumerated()), id: \.offset) { i, s in
                    if i > 0 {
                        Image(systemName: "sparkle").font(.system(size: 7)).foregroundColor(Theme.goldDeep).padding(.horizontal, 2)
                    }
                    VStack(spacing: 2) {
                        Text(script == "latin" ? s.latin : s.devanagari)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.goldGradient)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                        Text(s.deity).font(.system(size: 9, weight: .medium)).foregroundColor(Theme.dim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#1A1405"), Color.black], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.goldDeep.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Salutations to Sri Venkateshwara, Goddess Lakshmi and Kubera")
    }
}

/// Shown when the app opens.
struct SplashView: View {
    var onDone: () -> Void
    @AppStorage(Pref.mantraScript) private var script = "devanagari"
    @State private var step = 0
    @State private var glow = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [Theme.gold.opacity(glow ? 0.28 : 0.12), .clear], center: .center, startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glow)
            VStack(spacing: 22) {
                Image("Emblem")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .shadow(color: Theme.gold.opacity(0.5), radius: 18)
                    .opacity(step >= 1 ? 1 : 0)
                    .scaleEffect(step >= 1 ? 1 : 0.85)
                VStack(spacing: 10) {
                    ForEach(Array(Mantra.salutations.enumerated()), id: \.offset) { i, s in
                        VStack(spacing: 2) {
                            Text(script == "latin" ? s.latin : s.devanagari)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.goldGradient)
                            Text(s.deity).font(.caption).foregroundColor(Theme.dim)
                        }
                        .opacity(step >= 2 + i ? 1 : 0)
                        .offset(y: step >= 2 + i ? 0 : 8)
                    }
                }
                VStack(spacing: 8) {
                    Text(script == "latin" ? Mantra.kuberaLatin : Mantra.kuberaDevanagari)
                        .font(.system(size: 15, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.goldLight.opacity(0.95))
                        .lineSpacing(4)
                    Text("Kubera mantra for abundance").font(.caption2).foregroundColor(Theme.faint)
                }
                .padding(.horizontal, 24)
                .opacity(step >= 5 ? 1 : 0)
            }
            .padding(.bottom, 30)
            VStack {
                Spacer()
                Text("Tap to continue").font(.caption2).foregroundColor(Theme.faint).padding(.bottom, 24).opacity(step >= 5 ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDone() }
        .task {
            glow = true
            for s in 1...5 {
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.easeOut(duration: 0.45)) { step = s }
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            onDone()
        }
    }
}

/// Everything, with meanings.
struct MantraSheet: View {
    @AppStorage(Pref.mantraScript) private var script = "devanagari"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image("Emblem").resizable().scaledToFit().frame(width: 84, height: 84).shadow(color: Theme.gold.opacity(0.4), radius: 12)
                    VStack(spacing: 14) {
                        ForEach(Mantra.salutations) { s in
                            VStack(spacing: 3) {
                                Text(s.devanagari).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.goldGradient)
                                Text(s.latin).font(.footnote).foregroundColor(Theme.goldLight)
                                Text(s.deity).font(.caption).foregroundColor(Theme.dim)
                            }
                        }
                    }
                    .card(padding: 18)
                    mantraBlock(title: "Kubera mantra", deva: Mantra.kuberaDevanagari, latin: Mantra.kuberaLatin, meaning: Mantra.kuberaMeaning)
                    mantraBlock(title: "Lakshmi Gayatri", deva: Mantra.lakshmiGayatriDevanagari, latin: Mantra.lakshmiGayatriLatin, meaning: Mantra.lakshmiGayatriMeaning)
                    Picker("Script on the header", selection: $script) {
                        Text("देवनागरी").tag("devanagari")
                        Text("English letters").tag("latin")
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
            }
            .kuberaScreen()
            .navigationTitle("Shubham")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func mantraBlock(title: String, deva: String, latin: String, meaning: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline).foregroundColor(Theme.gold)
            Text(deva).font(.system(size: 18)).multilineTextAlignment(.center).lineSpacing(4)
            Text(latin).font(.footnote.italic()).foregroundColor(Theme.goldLight).multilineTextAlignment(.center)
            Text(meaning).font(.footnote).foregroundColor(Theme.dim).multilineTextAlignment(.center)
        }
        .card(padding: 18)
    }
}
