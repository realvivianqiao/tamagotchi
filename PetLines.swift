import Foundation

/// Big line pools so gestures don't feel repetitive. Shared by host pet + friend visitors.
enum PetLines {
  /// Prefer lines that aren't in the recent window.
  static func pick(_ pool: [String], recent: inout [String], keep: Int = 12) -> String {
    let fresh = pool.filter { !recent.contains($0) }
    let line = (fresh.isEmpty ? pool : fresh).randomElement()!
    recent.append(line)
    if recent.count > keep { recent.removeFirst(recent.count - keep) }
    return line
  }

  // MARK: Pet (click)

  static func pet(_ species: Species) -> [String] {
    switch species {
    case .dog:
      [
        "woof!", "best day!!", "more pets!!", "hehe~", "ear scritches!!",
        "good human ❤️", "belly rubs??", "aww~", "yesss", "pat pat!",
        "i'm melting", "soft…", "❤️❤️", "tail go brrr", "favorite!!",
        "don't stop", "mmmh", "squish!!", "love u", "cheek rubs",
        "happy bark!", "snuggle?", "warm…", "best pets", "again again!",
        "flop~", "sigh (happy)", "you're the best", "🥺❤️", "head empty only pets",
      ]
    case .bird:
      [
        "tweet!", "fluff!!", "♪", "chirp chirp", "preen me!",
        "soft feathers", "♡", "up!!", "sing~", "coo",
        "berry vibes", "happy hop", "wing hug", "✨", "don't ruffle… wait do",
        "nest feels", "tiny dance", "beep!", "more fluff", "ear— wait feathers",
        "sunshine!", "perch pets", "gentle!", "tweet of joy", "again?",
        "puff!!", "melodic~", "best human", "feather fluff ❤️", "chirp forever",
      ]
    case .octopus:
      [
        "bloop~", "pat pat", "🫧❤️", "squish!", "tentacle hug",
        "warm current", "ink? no… love", "drift happy", "soft squeeze", "♡ bloop",
        "more arms = more hugs", "gurgle~", "cozy", "float float", "squeeze!",
        "happy blob", "don't stop", "sea kisses", "🫧🫧", "gentle tide",
        "again please", "mushy~", "you're my reef", "pat the head", "bloop of joy",
        "wiggle!", "ink hearts", "hold me", "slow squeeze ❤️", "content…",
      ]
    }
  }

  // MARK: Feed

  static func feed(_ species: Species, secondBreakfast: Bool) -> [String] {
    if secondBreakfast {
      switch species {
      case .dog:
        return [
          "still hungry?? ok… 🍖", "second breakfast!!", "don't mind if i do",
          "more?? yes", "snack 2: electric boogaloo", "nom again",
          "never full honestly", "bonus treat!!", "chef's kiss", "ok one more…",
          "you spoil me", "food again? perfect", "crunch crunch II", "yes chef",
          "i was waiting", "second serving!!", "don't tell the vet", "hehe meat",
          "bottomless pit 🐶", "thank u (again)", "still nomming", "treat tax",
          "refill appreciated", "double dinner!", "i earned this", "woof (grateful)",
          "more bowl energy", "yes yes yes", "snack attack 2", "full…ish 🍖",
        ]
      case .bird:
        return [
          "more seeds!!", "second helping!!", "SEED AGAIN", "peck peck II",
          "berry encore", "never enough seeds", "crunch 2", "yes more!!",
          "tiny tummy lies", "refill the feeder", "nom seed", "happy beak",
          "seed economy booming", "again!", "peckish still", "tweet (fullish)",
          "snack perch", "more crumbs", "yes human", "seed jackpot",
          "double chirp meal", "keep em coming", "beak busy", "yum yum 2",
          "feeder hero", "seed goblin", "peck forever", "second nest snack",
          "berry bonus", "seed overflow!!",
        ]
      case .octopus:
        return [
          "second snack 🦀", "more crab??", "encore bloop", "snack tide rising",
          "still snacky", "crab 2", "bubble feast II", "yes more",
          "arms need calories", "gurgle (happy)", "reef buffet", "again please",
          "ink later, food now", "nom nom 2", "you're a good current", "🦀🦀",
          "bottomless blob", "second serving!", "drift + dine", "more!!",
          "snack vortex", "bloop thanks", "keep the crab coming", "hungry ink",
          "treat for tentacles", "yes chef crab", "refill the tide pool", "yum 2",
          "never refuse crab", "double bloop feast",
        ]
      }
    }
    switch species {
    case .dog:
      return [
        "nom nom 🍖", "crunch!!", "best meal", "thank u!!", "bowl empty already?",
        "mmm meat", "good food day", "woof (full)", "treat!!", "chef human!!",
        "nom…", "happy tummy", "bone?? alsook", "slurp", "dinner!!",
        "i love this", "food dance", "yum yum", "snack secured", "grateful bark",
        "more later?", "perfect bite", "nomming…", "taste tester 🐶", "feast mode",
        "belly +1", "crunch crunch", "so good", "meal of champions", "♡ food",
      ]
    case .bird:
      return [
        "peck peck!", "SEED!", "berry!!", "crunch seed", "beak happy",
        "yum chirp", "feeder full ♡", "tweet (nom)", "seed acquired", "peckish no more",
        "crumb dance", "tiny feast", "nom seed", "happy crop", "more? maybe",
        "berry blast", "seed perfection", "chirp thanks", "peck approved", "snack perch",
        "beak busy!", "crunchy good", "seed economy", "yum!!", "nest snack",
        "feather fuel", "peck peck peck", "delicious!", "seed goblin wins", "♡ crumbs",
      ]
    case .octopus:
      return [
        "nom bloop 🦀", "crab!!", "snack tide", "gurgle yum", "bloop feast",
        "tentacle nom", "🦀 delicious", "bubble dinner", "reef snack", "ink? nah food",
        "squish + snack", "yum current", "arms full of crab", "bloop thanks", "nom…",
        "happy blob meal", "snack secured", "drift & dine", "crab hug", "more later?",
        "taste the sea", "bubbly yum", "feast mode 🫧", "good human", "snack vortex",
        "nom nom", "crab approved", "belly bloop", "tide pool treat", "♡ 🦀",
      ]
    }
  }

  static func feedAsleep(_ species: Species, secondBreakfast: Bool) -> [String] {
    if secondBreakfast {
      return [
        "nom… (still asleep)", "dream snack…", "mmm… later wake", "sleep-eating!!",
        "zzz + nom", "unconscious crunch", "don't wake me… ok snack", "dream buffet",
        "sleep feast", "half-asleep nom", "zzz 🍖", "midnight snack (day)",
        "eyes closed, mouth open", "dream calories", "nap + food = win",
        "still dreaming of food", "zzz nom zzz", "pillow snack", "soft nom…",
        "don't judge the sleep-eat", "dream treat", "zzz… yum", "asleep but grateful",
        "snack in dreamland", "unbothered nomming", "sleep mode: eating", "zzz feast",
        "horizontal snacking", "nap calories", "still out, still hungry",
      ]
    }
    switch species {
    case .dog:
      return [
        "nom nom… 💤", "dream meat…", "zzz… yum", "sleep-nom", "mmh food",
        "dreaming of bowls", "zzz 🍖", "soft crunch…", "nap snack", "eyes shut nom",
        "pillow dinner", "zzz feast", "half bark, half snore", "dream treat",
        "horizontal dinner", "sleep mode nom", "grateful… asleep", "zzz yum zzz",
        "don't wake… snack ok", "dream belly rub + food", "soft…", "nap calories",
        "unconscious woof", "zzz… delicious", "asleep gourmet", "dream bone",
        "sleepy nom", "zzz bowl", "dream crunch", "still sleeping, still eating",
      ]
    case .bird:
      return [
        "peck… 💤", "dream seeds…", "zzz chirp nom", "roost snack", "sleepy peck",
        "dream feeder", "zzz SEED", "nest nom", "soft peck…", "asleep tweet-eat",
        "dream berry", "zzz yum", "roost buffet", "half fluff half food", "sleepy beak",
        "dream crumbs", "zzz peck", "nest dinner", "unconscious chirp", "seed dreams",
        "roost mode: nom", "zzz berry", "sleepy feast", "dream perch snack", "soft…",
        "asleep peeping", "zzz seed zzz", "dream crop full", "nest nomming", "zzz… yum",
      ]
    case .octopus:
      return [
        "bloop… 💤", "dream crab…", "zzz 🦀", "sand snack", "sleep bloop nom",
        "dream tide feast", "zzz yum", "bubble dinner (asleep)", "soft nom…",
        "ink dreams + crab", "zzz snack", "horizontal blob feast", "dream reef",
        "asleep gurgle", "sand nap nom", "zzz… delicious", "dream tentacle snack",
        "sleep current + food", "bloop (sleeping)", "zzz crab zzz", "soft squeeze snack",
        "dream buffet 🫧", "nap calories", "unconscious bloop", "zzz feast",
        "still drifting, still eating", "sand dinner", "dream yum", "zzz… 🦀", "sleepy snack tide",
      ]
    }
  }

  // MARK: Play

  static func play(_ species: Species) -> [String] {
    switch species {
    case .dog:
      [
        "ZOOMIES!! 🎾", "ball!!", "chase me!!", "park energy!!", "go go go!",
        "fetch??", "sprint!!", "woof WOOF", "can't catch me", "zoom zoom",
        "best game!!", "run run run", "🎾!!", "play bow!!", "zoomies activated",
        "full send!!", "race ya", "turbo dog", "wheee~", "more play!!",
        "agility course!!", "i'm so fast", "ball is life", "zoom tax", "play forever",
        "catch this!", "zoomies 2", "happy sprint", "game on!!", "💥🎾",
      ]
    case .bird:
      [
        "sky!! 🪶", "flyyy!", "up up!!", "wind!!", "soar~",
        "cloud hop", "tweet flight", "air dance", "higher!!", "glide!!",
        "feather rocket", "sky party", "flight mode", "whoosh 🪶", "loop!!",
        "perch to sky", "zoom wings", "air zoomies", "catch the wind", "updraft!!",
        "bird speed", "sky snack later", "feathers go brrr", "altitude!!", "chirp flight",
        "free as a… me", "sky!! again", "wing day", "fly with me", "✨🪶",
      ]
    case .octopus:
      [
        "whoosh 🌊", "current ride!!", "drift speed", "bubble jet!", "swim swim",
        "tide zoom", "ink later, play now", "wave!!", "float race", "bloop zoom",
        "reef dash", "tentacle turbo", "🌊!!", "splash play", "current go brrr",
        "drift games", "whoosh whoosh", "play tide", "bubble chase", "sea zoomies",
        "ink? nah play", "float faster", "ocean tag", "swim forever", "bloop jet",
        "wave rider", "tide party", "🫧 race", "deep play", "current!!",
      ]
    }
  }

  static func playAsleep(_ species: Species) -> [String] {
    [
      "…later. sleeping", "zzz — play tomorrow", "dreaming of games…", "nap first",
      "busy being horizontal", "ask again after roost", "sleep mode on", "zzz no fetch",
      "dream zoomies only", "not now… pillow", "later later", "eyes closed = closed",
      "schedule: nap", "play in my dreams", "zzz… maybe", "too comfy",
      "wake me for snacks not sprints", "horizontal athlete", "sleeping athlete", "zzz 🎾",
      "do not disturb", "dream park only", "nap > games (for now)", "shh…",
      "battery: sleeping", "come back later", "zzz world", "soft refuse", "asleep, politely",
      "queue that playdate",
    ]
  }

  // MARK: Poke / angry

  static func poke(_ species: Species) -> [String] {
    switch species {
    case .dog:
      [
        "hey!!", "grrr!", "was that needed", "rude!!", "ow— hey!",
        "excuse me?!", "don't poke!!", "grumble", "side eye 💢", "i saw that",
        "why!!", "mean human", "bark!!", "personal space!!", "grrr…",
        "not funny", "hey hey hey", "watch it", "i'm telling", "grumpy!!",
        "that tickled wrong", "stop!!", "💢!", "unbelievable", "woof (mad)",
        "boundary!!", "leave my nose", "grrr bark", "dramatic gasp", "i'm offended",
      ]
    case .bird:
      [
        "SQUAWK", "mean!!", "hey!!", "feathers ruffled!!", "rude chirp",
        "don't poke the bird", "tweet MAD", "personal wing space", "ow!!", "side eye",
        "why would you", "SQUAWK 2", "angry hop", "beak warning", "not cute",
        "i'll tell the flock", "mean human!!", "fluff rage", "chirp!!", "stop that",
        "wing slap incoming", "how dare", "tweet of protest", "💢 bird", "leave me",
        "ruffled!!", "squawk forever", "i'm small AND mad", "peck warning", "unbelievable!!",
      ]
    case .octopus:
      [
        "INK!!", "blorp— bye", "hey!!", "rude current", "don't poke!!",
        "ink cloud!!", "grumpy blob", "tentacle slap?", "why!!", "bloop MAD",
        "personal space (all 8)", "ink ink ink", "mean tide", "i saw that", "💢🫧",
        "squish protest", "leave the head", "dramatic ink", "bye (mad)", "how dare",
        "reef rage", "bloop!!", "ink apology later", "stop poking", "offended octopus",
        "cloud of disapproval", "mad drift", "ink you!", "boundary blob", "unbelievable",
      ]
    }
  }
}
