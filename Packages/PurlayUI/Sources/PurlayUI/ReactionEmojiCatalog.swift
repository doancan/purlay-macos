import Foundation

/// A curated Unicode catalogue. The wire value remains the emoji itself, shared by every client.
struct ReactionEmoji: Identifiable, Sendable {
    let symbol: String
    let name: String
    let keywords: String
    let category: EmojiCategory
    var id: String { symbol }
}

enum EmojiCategory: String, CaseIterable, Identifiable {
    case smileys, hearts, nature, food, activities, objects, symbols
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smileys: "Faces & People"
        case .hearts: "Hearts"
        case .nature: "Nature"
        case .food: "Food & Drink"
        case .activities: "Activities"
        case .objects: "Travel & Objects"
        case .symbols: "Symbols & Flags"
        }
    }
}

enum ReactionEmojiCatalog {
    static let quick = ["👍", "👎", "❤️", "😄", "🎉", "🚀", "👀", "🙏"]
    static let all: [ReactionEmoji] = [
        .init(symbol: "😀", name: "Grinning face", keywords: "gülümse mutlu happy smile", category: .smileys),
        .init(symbol: "😄", name: "Laughing face", keywords: "gülmek neşe laugh happy", category: .smileys),
        .init(symbol: "😁", name: "Beaming face", keywords: "gülümse diş grin", category: .smileys),
        .init(symbol: "😂", name: "Tears of joy", keywords: "kahkaha gülmek lol laugh", category: .smileys),
        .init(symbol: "🤣", name: "Rolling on the floor laughing", keywords: "kahkaha lol rofl", category: .smileys),
        .init(symbol: "😊", name: "Smiling face", keywords: "mutlu gülümse happy", category: .smileys),
        .init(symbol: "🙂", name: "Slightly smiling face", keywords: "gülümse smile", category: .smileys),
        .init(symbol: "😉", name: "Winking face", keywords: "göz kırp wink", category: .smileys),
        .init(symbol: "😍", name: "Heart eyes", keywords: "aşk sevgi love", category: .smileys),
        .init(symbol: "🥰", name: "Smiling face with hearts", keywords: "sevgi aşk love", category: .smileys),
        .init(symbol: "😘", name: "Blowing a kiss", keywords: "öpücük kiss love", category: .smileys),
        .init(symbol: "😎", name: "Sunglasses", keywords: "havalı cool güneş", category: .smileys),
        .init(symbol: "🤓", name: "Nerd face", keywords: "inek gözlük nerd", category: .smileys),
        .init(symbol: "🧐", name: "Monocle face", keywords: "incele merak curious", category: .smileys),
        .init(symbol: "🤔", name: "Thinking face", keywords: "düşün düşünce think", category: .smileys),
        .init(symbol: "🤨", name: "Raised eyebrow", keywords: "şüphe doubt", category: .smileys),
        .init(symbol: "😐", name: "Neutral face", keywords: "ifadesiz neutral", category: .smileys),
        .init(symbol: "🙄", name: "Rolling eyes", keywords: "göz devir roll", category: .smileys),
        .init(symbol: "😏", name: "Smirking face", keywords: "sırıt smirk", category: .smileys),
        .init(symbol: "😴", name: "Sleeping face", keywords: "uyku sleep tired", category: .smileys),
        .init(symbol: "🥱", name: "Yawning face", keywords: "esneme uykulu tired", category: .smileys),
        .init(symbol: "😅", name: "Smiling face with sweat", keywords: "ter rahatlama sweat", category: .smileys),
        .init(symbol: "😬", name: "Grimacing face", keywords: "gergin awkward", category: .smileys),
        .init(symbol: "🫠", name: "Melting face", keywords: "erime sıcak melt", category: .smileys),
        .init(symbol: "🙃", name: "Upside-down face", keywords: "ters upside down", category: .smileys),
        .init(symbol: "🤗", name: "Hugging face", keywords: "sarıl hug", category: .smileys),
        .init(symbol: "🤭", name: "Hand over mouth", keywords: "şaşır giggle", category: .smileys),
        .init(symbol: "🫢", name: "Open eyes and hand over mouth", keywords: "şaşkın surprise", category: .smileys),
        .init(symbol: "🤫", name: "Shushing face", keywords: "sessiz sus quiet", category: .smileys),
        .init(symbol: "🤩", name: "Star eyes", keywords: "hayran yıldız excited", category: .smileys),
        .init(symbol: "🥳", name: "Partying face", keywords: "parti kutlama celebrate", category: .smileys),
        .init(symbol: "😇", name: "Smiling face with halo", keywords: "melek angel", category: .smileys),
        .init(symbol: "🥹", name: "Holding back tears", keywords: "duygusal gözyaşı emotional", category: .smileys),
        .init(symbol: "🥺", name: "Pleading face", keywords: "lütfen yalvar please", category: .smileys),
        .init(symbol: "😢", name: "Crying face", keywords: "ağla üzgün sad cry", category: .smileys),
        .init(symbol: "😭", name: "Loudly crying face", keywords: "ağlamak üzgün sob", category: .smileys),
        .init(symbol: "😔", name: "Pensive face", keywords: "üzgün sad", category: .smileys),
        .init(symbol: "😮", name: "Open mouth", keywords: "şaşkın surprised", category: .smileys),
        .init(symbol: "😱", name: "Screaming face", keywords: "çığlık korku scream", category: .smileys),
        .init(symbol: "🤯", name: "Exploding head", keywords: "şaşkın mind blown", category: .smileys),
        .init(symbol: "😳", name: "Flushed face", keywords: "utanma blush", category: .smileys),
        .init(symbol: "😡", name: "Angry face", keywords: "kızgın öfke angry", category: .smileys),
        .init(symbol: "🤬", name: "Swearing face", keywords: "küfür öfke swear", category: .smileys),
        .init(symbol: "😤", name: "Huffing face", keywords: "sinir kızgın huff", category: .smileys),
        .init(symbol: "🤦", name: "Facepalm", keywords: "yüz el face palm", category: .smileys),
        .init(symbol: "🤷", name: "Shrug", keywords: "bilmem omuz shrug", category: .smileys),
        .init(symbol: "🤝", name: "Handshake", keywords: "anlaşma el sıkış deal", category: .smileys),
        .init(symbol: "👋", name: "Waving hand", keywords: "merhaba selam veda hello bye", category: .smileys),
        .init(symbol: "👍", name: "Thumbs up", keywords: "beğen onay tamam yes approve", category: .smileys),
        .init(symbol: "👎", name: "Thumbs down", keywords: "beğenme hayır no disapprove", category: .smileys),
        .init(symbol: "👏", name: "Clapping hands", keywords: "alkış bravo clap", category: .smileys),
        .init(symbol: "🙌", name: "Raising hands", keywords: "yaşasın kutlama hooray", category: .smileys),
        .init(
            symbol: "🙏", name: "Folded hands", keywords: "teşekkür lütfen dua thanks please pray", category: .smileys),
        .init(symbol: "👌", name: "OK hand", keywords: "tamam mükemmel okay perfect", category: .smileys),
        .init(symbol: "✌️", name: "Victory hand", keywords: "barış zafer peace victory", category: .smileys),
        .init(symbol: "🤞", name: "Crossed fingers", keywords: "şans luck fingers", category: .smileys),
        .init(symbol: "🤟", name: "Love-you gesture", keywords: "sevgi love", category: .smileys),
        .init(symbol: "🤘", name: "Sign of the horns", keywords: "rock metal", category: .smileys),
        .init(symbol: "💪", name: "Flexed biceps", keywords: "güç güçlü strong muscle", category: .smileys),
        .init(symbol: "👀", name: "Eyes", keywords: "göz bak takip look watching", category: .smileys),
        .init(symbol: "🧠", name: "Brain", keywords: "beyin zeka idea", category: .smileys),
        .init(symbol: "❤️", name: "Red heart", keywords: "kırmızı kalp sevgi aşk love", category: .hearts),
        .init(symbol: "🧡", name: "Orange heart", keywords: "turuncu kalp sevgi love", category: .hearts),
        .init(symbol: "💛", name: "Yellow heart", keywords: "sarı kalp sevgi love", category: .hearts),
        .init(symbol: "💚", name: "Green heart", keywords: "yeşil kalp sevgi love", category: .hearts),
        .init(symbol: "💙", name: "Blue heart", keywords: "mavi kalp sevgi love", category: .hearts),
        .init(symbol: "💜", name: "Purple heart", keywords: "mor kalp sevgi love", category: .hearts),
        .init(symbol: "🖤", name: "Black heart", keywords: "siyah kalp love", category: .hearts),
        .init(symbol: "🤍", name: "White heart", keywords: "beyaz kalp love", category: .hearts),
        .init(symbol: "🤎", name: "Brown heart", keywords: "kahverengi kalp love", category: .hearts),
        .init(symbol: "💔", name: "Broken heart", keywords: "kırık kalp üzgün sad", category: .hearts),
        .init(symbol: "❤️‍🔥", name: "Heart on fire", keywords: "ateş kalp aşk love", category: .hearts),
        .init(symbol: "💕", name: "Two hearts", keywords: "iki kalp love", category: .hearts),
        .init(symbol: "💖", name: "Sparkling heart", keywords: "parlak kalp sevgi love", category: .hearts),
        .init(symbol: "💯", name: "Hundred points", keywords: "yüz tam perfect", category: .hearts),
        .init(symbol: "💥", name: "Collision", keywords: "patlama boom", category: .hearts),
        .init(symbol: "💫", name: "Dizzy", keywords: "baş dönmesi yıldız dizzy", category: .hearts),
        .init(symbol: "💤", name: "Sleeping symbol", keywords: "uyku sleep zzz", category: .hearts),
        .init(symbol: "🐱", name: "Cat", keywords: "kedi", category: .nature),
        .init(symbol: "🐶", name: "Dog", keywords: "köpek", category: .nature),
        .init(symbol: "🐭", name: "Mouse", keywords: "fare", category: .nature),
        .init(symbol: "🐹", name: "Hamster", keywords: "hamster", category: .nature),
        .init(symbol: "🐰", name: "Rabbit", keywords: "tavşan", category: .nature),
        .init(symbol: "🦊", name: "Fox", keywords: "tilki", category: .nature),
        .init(symbol: "🐻", name: "Bear", keywords: "ayı", category: .nature),
        .init(symbol: "🐼", name: "Panda", keywords: "panda", category: .nature),
        .init(symbol: "🐨", name: "Koala", keywords: "koala", category: .nature),
        .init(symbol: "🐯", name: "Tiger", keywords: "kaplan", category: .nature),
        .init(symbol: "🦁", name: "Lion", keywords: "aslan", category: .nature),
        .init(symbol: "🐮", name: "Cow", keywords: "inek", category: .nature),
        .init(symbol: "🐷", name: "Pig", keywords: "domuz", category: .nature),
        .init(symbol: "🐸", name: "Frog", keywords: "kurbağa", category: .nature),
        .init(symbol: "🐵", name: "Monkey", keywords: "maymun", category: .nature),
        .init(symbol: "🐧", name: "Penguin", keywords: "penguen", category: .nature),
        .init(symbol: "🐥", name: "Chick", keywords: "civciv", category: .nature),
        .init(symbol: "🦆", name: "Duck", keywords: "ördek", category: .nature),
        .init(symbol: "🦋", name: "Butterfly", keywords: "kelebek", category: .nature),
        .init(symbol: "🐝", name: "Honeybee", keywords: "arı", category: .nature),
        .init(symbol: "🐛", name: "Bug", keywords: "böcek hata", category: .nature),
        .init(symbol: "🐢", name: "Turtle", keywords: "kaplumbağa yavaş slow", category: .nature),
        .init(symbol: "🐙", name: "Octopus", keywords: "ahtapot", category: .nature),
        .init(symbol: "🦄", name: "Unicorn", keywords: "tek boynuz at", category: .nature),
        .init(symbol: "🌸", name: "Cherry blossom", keywords: "çiçek bahar flower", category: .nature),
        .init(symbol: "🌻", name: "Sunflower", keywords: "ayçiçeği çiçek flower", category: .nature),
        .init(symbol: "🌹", name: "Rose", keywords: "gül çiçek flower", category: .nature),
        .init(symbol: "🌱", name: "Seedling", keywords: "fidan büyüme grow", category: .nature),
        .init(symbol: "🌳", name: "Tree", keywords: "ağaç", category: .nature),
        .init(symbol: "🍀", name: "Four-leaf clover", keywords: "yonca şans lucky", category: .nature),
        .init(symbol: "☀️", name: "Sun", keywords: "güneş sunny", category: .nature),
        .init(symbol: "🌙", name: "Moon", keywords: "ay gece night", category: .nature),
        .init(symbol: "⭐", name: "Star", keywords: "yıldız", category: .nature),
        .init(symbol: "🌈", name: "Rainbow", keywords: "gökkuşağı", category: .nature),
        .init(symbol: "🔥", name: "Fire", keywords: "ateş hot", category: .nature),
        .init(symbol: "❄️", name: "Snowflake", keywords: "kar soğuk cold", category: .nature),
        .init(symbol: "⚡", name: "Lightning", keywords: "şimşek yıldırım fast", category: .nature),
        .init(symbol: "🌊", name: "Water wave", keywords: "dalga deniz ocean", category: .nature),
        .init(symbol: "☕", name: "Coffee", keywords: "kahve mola break", category: .food),
        .init(symbol: "🍵", name: "Tea", keywords: "çay mola break", category: .food),
        .init(symbol: "🥛", name: "Milk", keywords: "süt", category: .food),
        .init(symbol: "💧", name: "Water drop", keywords: "su damla", category: .food),
        .init(symbol: "🍎", name: "Apple", keywords: "elma", category: .food),
        .init(symbol: "🍌", name: "Banana", keywords: "muz", category: .food),
        .init(symbol: "🍉", name: "Watermelon", keywords: "karpuz", category: .food),
        .init(symbol: "🍓", name: "Strawberry", keywords: "çilek", category: .food),
        .init(symbol: "🍒", name: "Cherries", keywords: "kiraz", category: .food),
        .init(symbol: "🥑", name: "Avocado", keywords: "avokado", category: .food),
        .init(symbol: "🥕", name: "Carrot", keywords: "havuç", category: .food),
        .init(symbol: "🍞", name: "Bread", keywords: "ekmek", category: .food),
        .init(symbol: "🥐", name: "Croissant", keywords: "kruvasan kahvaltı", category: .food),
        .init(symbol: "🧀", name: "Cheese", keywords: "peynir", category: .food),
        .init(symbol: "🍕", name: "Pizza", keywords: "pizza", category: .food),
        .init(symbol: "🍔", name: "Burger", keywords: "hamburger", category: .food),
        .init(symbol: "🍟", name: "French fries", keywords: "patates kızartma", category: .food),
        .init(symbol: "🌮", name: "Taco", keywords: "taco", category: .food),
        .init(symbol: "🍿", name: "Popcorn", keywords: "patlamış mısır", category: .food),
        .init(symbol: "🍜", name: "Noodles", keywords: "erişte noodle", category: .food),
        .init(symbol: "🍣", name: "Sushi", keywords: "suşi", category: .food),
        .init(symbol: "🍦", name: "Ice cream", keywords: "dondurma", category: .food),
        .init(symbol: "🍩", name: "Doughnut", keywords: "donut tatlı", category: .food),
        .init(symbol: "🍪", name: "Cookie", keywords: "kurabiye", category: .food),
        .init(symbol: "🎂", name: "Birthday cake", keywords: "doğum günü pasta birthday", category: .food),
        .init(symbol: "🍰", name: "Cake", keywords: "pasta tatlı", category: .food),
        .init(symbol: "🍫", name: "Chocolate", keywords: "çikolata", category: .food),
        .init(symbol: "🍻", name: "Clinking beer mugs", keywords: "bira şerefe cheers", category: .food),
        .init(symbol: "🥂", name: "Clinking glasses", keywords: "şerefe kutlama cheers", category: .food),
        .init(
            symbol: "🎉", name: "Party popper", keywords: "kutlama tebrik parti celebrate congratulations",
            category: .activities),
        .init(symbol: "🎊", name: "Confetti ball", keywords: "konfeti kutlama celebrate", category: .activities),
        .init(symbol: "🎈", name: "Balloon", keywords: "balon parti party", category: .activities),
        .init(symbol: "🎁", name: "Gift", keywords: "hediye present", category: .activities),
        .init(symbol: "🏆", name: "Trophy", keywords: "kupa başarı ödül winner", category: .activities),
        .init(symbol: "🥇", name: "Gold medal", keywords: "altın madalya birinci first", category: .activities),
        .init(symbol: "🏅", name: "Medal", keywords: "madalya başarı ödül award", category: .activities),
        .init(symbol: "🎯", name: "Bullseye", keywords: "hedef isabet target", category: .activities),
        .init(symbol: "🎮", name: "Video game", keywords: "oyun game", category: .activities),
        .init(symbol: "🎲", name: "Dice", keywords: "zar şans random", category: .activities),
        .init(symbol: "🎨", name: "Artist palette", keywords: "sanat çizim design art", category: .activities),
        .init(symbol: "🎵", name: "Musical note", keywords: "müzik music", category: .activities),
        .init(symbol: "🎶", name: "Musical notes", keywords: "müzik music", category: .activities),
        .init(symbol: "🎸", name: "Guitar", keywords: "gitar müzik music", category: .activities),
        .init(symbol: "🎬", name: "Clapper board", keywords: "film sinema movie", category: .activities),
        .init(symbol: "⚽", name: "Soccer ball", keywords: "futbol football", category: .activities),
        .init(symbol: "🏀", name: "Basketball", keywords: "basketbol", category: .activities),
        .init(symbol: "🎾", name: "Tennis", keywords: "tenis", category: .activities),
        .init(symbol: "🏃", name: "Running", keywords: "koşu koş run", category: .activities),
        .init(symbol: "🚴", name: "Cycling", keywords: "bisiklet bike", category: .activities),
        .init(symbol: "🚀", name: "Rocket", keywords: "roket fırlat yayın launch ship", category: .objects),
        .init(symbol: "✈️", name: "Airplane", keywords: "uçak seyahat travel", category: .objects),
        .init(symbol: "🚗", name: "Car", keywords: "araba otomobil", category: .objects),
        .init(symbol: "🚲", name: "Bicycle", keywords: "bisiklet", category: .objects),
        .init(symbol: "🏠", name: "House", keywords: "ev home", category: .objects),
        .init(symbol: "🏖️", name: "Beach", keywords: "plaj tatil vacation", category: .objects),
        .init(symbol: "🌍", name: "Globe", keywords: "dünya earth world", category: .objects),
        .init(symbol: "💻", name: "Laptop", keywords: "bilgisayar kod computer code", category: .objects),
        .init(symbol: "🖥️", name: "Desktop computer", keywords: "masaüstü bilgisayar", category: .objects),
        .init(symbol: "📱", name: "Mobile phone", keywords: "telefon mobile", category: .objects),
        .init(symbol: "⌨️", name: "Keyboard", keywords: "klavye yazı typing", category: .objects),
        .init(symbol: "🖱️", name: "Computer mouse", keywords: "fare bilgisayar", category: .objects),
        .init(symbol: "💡", name: "Light bulb", keywords: "ampul fikir idea", category: .objects),
        .init(symbol: "🔧", name: "Wrench", keywords: "anahtar tamir fix tool", category: .objects),
        .init(symbol: "🔨", name: "Hammer", keywords: "çekiç inşa build", category: .objects),
        .init(symbol: "⚙️", name: "Gear", keywords: "dişli ayar settings", category: .objects),
        .init(symbol: "🔒", name: "Locked", keywords: "kilit güvenlik security", category: .objects),
        .init(symbol: "🔑", name: "Key", keywords: "anahtar erişim access", category: .objects),
        .init(symbol: "📌", name: "Pushpin", keywords: "raptiye sabitle pin", category: .objects),
        .init(symbol: "📎", name: "Paperclip", keywords: "ataç ek attachment", category: .objects),
        .init(symbol: "📝", name: "Memo", keywords: "not yazı note", category: .objects),
        .init(symbol: "📚", name: "Books", keywords: "kitap okuma read", category: .objects),
        .init(symbol: "📅", name: "Calendar", keywords: "takvim tarih date", category: .objects),
        .init(symbol: "⏰", name: "Alarm clock", keywords: "alarm saat time", category: .objects),
        .init(symbol: "⌛", name: "Hourglass", keywords: "kum saati bekle waiting", category: .objects),
        .init(symbol: "📣", name: "Megaphone", keywords: "duyuru announcement", category: .objects),
        .init(symbol: "🔔", name: "Bell", keywords: "zil bildirim notification", category: .objects),
        .init(symbol: "📦", name: "Package", keywords: "paket teslim delivery", category: .objects),
        .init(symbol: "🧹", name: "Broom", keywords: "süpürge temizle cleanup", category: .objects),
        .init(symbol: "🧪", name: "Test tube", keywords: "deney test", category: .objects),
        .init(symbol: "✅", name: "Check mark", keywords: "onay tamam bitti done yes approved", category: .symbols),
        .init(symbol: "❌", name: "Cross mark", keywords: "hayır iptal hata no cancel", category: .symbols),
        .init(symbol: "❎", name: "Cross mark button", keywords: "hayır iptal no", category: .symbols),
        .init(symbol: "⚠️", name: "Warning", keywords: "uyarı dikkat caution", category: .symbols),
        .init(symbol: "🚧", name: "Construction", keywords: "çalışma yapım work progress", category: .symbols),
        .init(symbol: "⛔", name: "No entry", keywords: "yasak dur stop", category: .symbols),
        .init(symbol: "🚫", name: "Prohibited", keywords: "yasak hayır no", category: .symbols),
        .init(symbol: "❓", name: "Question mark", keywords: "soru question", category: .symbols),
        .init(symbol: "❗", name: "Exclamation mark", keywords: "ünlem önemli important", category: .symbols),
        .init(symbol: "‼️", name: "Double exclamation", keywords: "ünlem önemli important", category: .symbols),
        .init(symbol: "⁉️", name: "Exclamation question mark", keywords: "soru şaşkın surprise", category: .symbols),
        .init(symbol: "➕", name: "Plus", keywords: "artı ekle add", category: .symbols),
        .init(symbol: "➖", name: "Minus", keywords: "eksi çıkar remove", category: .symbols),
        .init(symbol: "♻️", name: "Recycling", keywords: "geri dönüşüm recycle", category: .symbols),
        .init(
            symbol: "🔄", name: "Counterclockwise arrows", keywords: "yenile tekrar refresh retry", category: .symbols),
        .init(symbol: "🔜", name: "Soon arrow", keywords: "yakında soon", category: .symbols),
        .init(symbol: "🔝", name: "Top arrow", keywords: "üst yukarı top", category: .symbols),
        .init(symbol: "🟢", name: "Green circle", keywords: "yeşil çevrimiçi online", category: .symbols),
        .init(symbol: "🟡", name: "Yellow circle", keywords: "sarı bekle waiting", category: .symbols),
        .init(symbol: "🔴", name: "Red circle", keywords: "kırmızı dur stop", category: .symbols),
        .init(symbol: "🔵", name: "Blue circle", keywords: "mavi", category: .symbols),
        .init(symbol: "🏳️", name: "White flag", keywords: "beyaz bayrak teslim surrender", category: .symbols),
        .init(symbol: "🏁", name: "Chequered flag", keywords: "bitiş tamam finish", category: .symbols),
        .init(symbol: "🇹🇷", name: "Flag of Türkiye", keywords: "türkiye türk turkish turkey bayrak", category: .symbols),
        .init(
            symbol: "🇬🇧", name: "Flag of United Kingdom", keywords: "ingiltere british english bayrak",
            category: .symbols),
        .init(symbol: "🇺🇸", name: "Flag of United States", keywords: "amerika american bayrak", category: .symbols),
    ]

    static func matching(_ query: String, category: EmojiCategory? = nil) -> [ReactionEmoji] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace)
        return all.filter { emoji in
            guard category == nil || emoji.category == category else { return false }
            let text = normalized("\(emoji.symbol) \(emoji.name) \(emoji.keywords)")
            return terms.allSatisfy { text.contains($0) }
        }
    }

    static func recent(_ stored: String) -> [ReactionEmoji] {
        var seen = Set<String>()
        return stored.split(separator: "|").compactMap { symbol in
            guard seen.insert(String(symbol)).inserted else { return nil }
            return all.first { $0.symbol == symbol }
        }.prefix(16).map { $0 }
    }

    static func recording(_ symbol: String, in stored: String) -> String {
        guard all.contains(where: { $0.symbol == symbol }) else { return stored }
        return ([symbol] + recent(stored).map(\.symbol).filter { $0 != symbol })
            .prefix(16).joined(separator: "|")
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
