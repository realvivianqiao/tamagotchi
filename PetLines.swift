import Foundation

/// Big line pools so gestures don't feel repetitive. Shared by host pet + friend visitors.
///
/// Voices:
/// - dog — warm golden: calm, soft, endlessly fond
/// - bird — chaotic spark: hyped, half-finished thoughts, always mid-jump
/// - octopus — dry menace: sharp, savvy, suddenly too smart
enum PetLines {
  /// Prefer lines that aren't in the recent window.
  static func pick(_ pool: [String], recent: inout [String], keep: Int = 12) -> String {
    let fresh = pool.filter { !recent.contains($0) }
    let line = (fresh.isEmpty ? pool : fresh).randomElement()!
    recent.append(line)
    if recent.count > keep { recent.removeFirst(recent.count - keep) }
    return line
  }

  // MARK: Body-part touch (single click)

  static func touch(_ species: Species, _ part: BodyPart) -> [String] {
    switch (species, part) {
    case (.dog, .nose):
      return [
        "ah— nose… soft no", "boop… i don't love that", "tender!! careful",
        "hey… that's my nose", "startled snout…", "gentle on the nose please",
        "ow-adjacent…", "nose is sacred… mostly", "boop registered. mixed feelings.",
      ]
    case (.dog, .head), (.dog, .ear):
      return [
        "mmm head pets…", "ear scritches YES", "i love this", "best spot…",
        "keep going… soft", "golden brain melts", "forehead kisses accepted",
        "ear fluff heaven", "don't stop the head pets", "favorite place…",
      ]
    case (.dog, .belly):
      return [
        "belly… trust mode", "ok you may…", "vulnerable but happy",
        "soft tummy… careful joy", "roll? maybe. pets yes.", "belly rights granted",
      ]
    case (.dog, .limb):
      return [
        "that's a paw…", "shake? or just hold?", "bean inspection?",
        "foot tickles…", "paw held. confusing. nice.",
      ]
    case (.dog, .tail):
      return [
        "tail!! careful", "that's the antenna of joy", "gentle on the wag",
        "tail touch… weird but ok", "don't yank… just say hi",
      ]
    case (.dog, .body):
      return pet(.dog)

    case (.bird, .nose):
      return [
        "BEAK!! why!!", "boop the beak?? rude-cute", "peck zone!! hands off-ish",
        "that's for seeds not fingers!!", "beak privacy!! then ooh wait",
        "SQUAWK— soft squawk", "nose? BEAK. respect it!!",
      ]
    case (.bird, .head), (.bird, .ear):
      return [
        "tuft pets YES!!", "head fluff GO", "preen partner!!", "touch the tuft!! more!!",
        "brain scritches accepted!!", "favorite!! already forgetting why",
        "head= dopamine button", "soft chaos approved",
      ]
    case (.bird, .belly):
      return [
        "belly fluff!!", "cream tummy tax!!", "ticklish!! also more",
        "soft underside YES", "don't squeeze— scritch!!",
      ]
    case (.bird, .limb):
      return [
        "wing!! not a handle", "feathers are NOT levers", "foot bean?? ok weird",
        "wing pets… careful!!", "that's for flying not grabbing!!",
      ]
    case (.bird, .tail):
      return [
        "back fluff!!", "almost a tail. almost.", "gentle!!",
      ]
    case (.bird, .body):
      return pet(.bird)

    case (.octopus, .nose):
      return [
        "face. bold choice.", "mouth zone. reconsider.", "i bite. hypothetically.",
        "that was a statement.", "face poke logged. unimpressed.",
        "try the brain next time. higher.",
      ]
    case (.octopus, .head), (.octopus, .ear):
      return [
        "acceptable head touch", "crown of menace… fine", "soft spot. don't tell.",
        "hm. competent scritch.", "head pets. briefly approved.",
        "you're improving.", "…continue. quietly.",
      ]
    case (.octopus, .belly):
      return [
        "core access. noted.", "belly. vulnerable. still smarter.",
        "squish allowed. judgment continues.", "don't get sentimental.",
      ]
    case (.octopus, .limb):
      return [
        "that's an arm. one of eight.", "limb inspection. passable.",
        "arm ≠ toy. mostly.",
      ]
    case (.octopus, .tail):
      return [
        "tentacle. not a rope.", "pick a limb. gently.", "arm rights exist.",
        "that's for scheming. and gripping.",
      ]
    case (.octopus, .body):
      return pet(.octopus)
    }
  }

  /// Dragging a sensitive bit (tail / tentacle / wing).
  static func pull(_ species: Species, _ part: BodyPart) -> [String] {
    switch species {
    case .dog:
      if part == .tail {
        return [
          "ah— don't pull so hard!!", "tail is not a leash!!", "ow the wag!!",
          "gentle!! that's attached!!", "hey!! soft tug only", "TAIL RIGHTS",
        ]
      }
      return [
        "put me down… carefully", "whoa— easy", "i'm not a stuffed toy!!",
        "carry mode… nervous",
      ]
    case .bird:
      if part == .limb {
        return [
          "NOT A HANDLE!!", "wing!! release!!", "i need those for CHAOS flight",
          "feathers ≠ grip points!!", "put the wing DOWN— wait UP— STOP",
        ]
      }
      return [
        "not a kite!!", "airborne without consent!!", "zoom but wrong zoom!!",
      ]
    case .octopus:
      if part == .tail {
        return [
          "tentacle. not a rope.", "unhand the arm.", "i have seven more. still mad.",
          "pull again. see what happens.", "arm ≠ leash. savvy tip.",
          "ink incoming if you insist.",
        ]
      }
      return [
        "tentacles!!", "i allowed lift. barely.", "put. me. down.",
      ]
    }
  }

  // MARK: Pet (click)

  static func pet(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "aww…", "that's nice", "mmm soft", "good human", "ear scritches…",
        "warm…", "i like this", "gentle please~", "❤️", "tail thump",
        "you're kind", "best lap", "slow pets…", "cozy", "love you",
        "happy sigh", "don't stop… soft", "golden mood", "safe here", "cheek warm",
        "snuggle ok?", "quiet joy", "favorite person", "soft woof", "melting…",
        "thank you", "calm…", "good day already", "near you is enough", "❤️…",
      ]
    case .bird:
      return [
        "WAIT pets— YES", "preen PREEN", "oh! fluff!!", "again again AGAIN",
        "touch the tuft!!", "wait was that— more!", "hyper fluff!!", "beep!!",
        "can't sit still— pet!!", "wing wiggle YES", "ooh ooh ooh", "focus? no. pets.",
        "side quest: cuddles", "too much energy for this!!", "FLUFF TAX", "♪!!",
        "wait i was gonna— pets ok", "zoom but soft", "distractible bird loves this",
        "chirp interrupt!!", "hold still? never. pets tho", "sparkle brain + pets",
        "yes yes yes wait yes", "feather dopamine!!", "ADHD approved scritch",
        "ooh shiny affection", "can't finish a thou— PETS", "more!! already!!",
      ]
    case .octopus:
      return [
        "hm. acceptable.", "don't get used to this", "…fine.", "you're lucky i have 8 arms",
        "pathetic. cute.", "i'll allow it", "noted. soft.", "charm won't save you forever",
        "squish granted", "you're improving", "don't look so proud", "ink later. pets now.",
        "surprisingly competent human", "i saw that smile", "keep going. quietly.",
        "i'm not melting. (lying)", "your technique: mid+", "one arm says thanks. seven judge you",
        "don't tell the reef", "affection logged", "you're soft. i'm not. (mostly)",
        "ok… that was good", "menace offline. briefly.", "continue.", "hmph. ❤️",
      ]
    }
  }

  // MARK: Feed

  static func feed(_ species: Species, secondBreakfast: Bool) -> [String] {
    if secondBreakfast {
      switch species {
      case .dog:
        return [
          "oh… more? thank you", "second bowl… soft yes", "you spoil me gently",
          "i'll take it… warmly", "bonus treat. grateful.", "still room… for you",
          "calm crunch again", "didn't ask. still happy.", "slow nom… again",
          "you're too good", "second breakfast, soft mode", "mmm… kind",
          "full heart + full belly", "quiet thank-you nom", "golden seconds",
          "i was content. now more content.", "gentle feast 2", "woof… soft",
          "don't tell anyone how loved i am", "warm leftovers? perfect",
        ]
      case .bird:
        return [
          "SEED 2!! WAIT 3!!", "already?? YES", "brain: more crumbs NOW",
          "can't— seed— focus— SEED", "encore peck!!", "dopamine feeder!!",
          "i forgot i ate. eating again!!", "berry speedrun", "snack interrupt!!",
          "side quest: more food", "beak busy forever", "who needs impulse control",
          "SEED ECONOMY CRASH (good)", "wait was that— MORE", "hyper nom 2!!",
          "tiny tummy, huge chaos", "peck peck PECK", "again before i forget!!",
        ]
      case .octopus:
        return [
          "greedy? observant.", "second crab. predictable.", "i'll take it. obviously.",
          "your bribery works", "calories for scheming", "encore. don't gloat.",
          "i calculated you'd offer again", "acceptable sequel", "crab 2: the reckoning",
          "feeding the menace. brave.", "noted: soft touch + food", "still not impressed. (lying)",
          "arms require funding", "you spoil villains now?", "fine. delicious.",
          "intelligence needs snacks", "transaction complete", "hm. generous.",
        ]
      }
    }
    switch species {
    case .dog:
      return [
        "thank you…", "mmm warm food", "best human", "gentle nom", "so good",
        "happy tummy", "slow crunch…", "i love this", "kind feast", "woof… soft",
        "bowl joy", "you remembered", "cozy dinner", "grateful bark", "perfect bite",
        "calm feast", "♡ food", "sitting nicely… nom", "warm… full", "good meal day",
        "treat with love", "soft slurp", "belly happy", "you're the best chef", "mmm…",
      ]
    case .bird:
      return [
        "SEED!!", "berry— wait SEED", "peck attack!!", "food shiny!!", "nom FAST",
        "can't talk eating!!", "crumb chaos!!", "beak GO", "ooh snack shiny",
        "hyper nom!!", "seed acquired (sprint)", "focus: FOOD only", "chirp-crunch!!",
        "wait savoring— nah SPEED", "berry dopamine!!", "feeder jackpot!!",
        "tiny feast MAX volume", "peck peck peck!!", "i saw crumbs. i WON",
        "snack side quest complete!!", "yum then ZOOM", "crop go brrr",
      ]
    case .octopus:
      return [
        "crab. finally.", "adequate.", "i'll grade this later", "🦀… acceptable",
        "you feed the villain. noted.", "taste: fine. company: louder.",
        "calories for evil plans", "don't watch me eat", "hm. seasoned well enough",
        "transaction: food for peace", "i expected this. still good.", "nom. judgment reserved.",
        "reef Michelin? mid. edible.", "arms approve. face doesn't.", "thanks. begrudgingly.",
        "fuel for smarter insults", "delicious. you're welcome for my company",
      ]
    }
  }

  static func feedAsleep(_ species: Species, secondBreakfast: Bool) -> [String] {
    if secondBreakfast {
      return [
        "nom… (still asleep)", "dream snack…", "mmm… later wake", "sleep-eating!!",
        "zzz + nom", "unconscious crunch", "don't wake me… ok snack", "dream buffet",
      ]
    }
    switch species {
    case .dog:
      return [
        "mmm… soft…", "dream treats…", "zzz… thank you", "gentle nom…",
        "warm… asleep", "sleepy grateful", "zzz 🍖", "soft crunch…",
        "nap snack… kind", "eyes shut. heart full.", "pillow dinner…",
        "zzz… love you", "horizontal thank-you", "dream belly…",
      ]
    case .bird:
      return [
        "SEED— zzz— SEED", "dream crumbs!! wait", "peck… asleep?? yes",
        "roost snack interrupt!!", "zzz but HYPER mouth", "dream feeder GO",
        "half asleep half PECK", "nest nom chaos", "zzz berry dopamine",
        "can't rest. can eat.", "asleep speedrun snack", "chirp-nom-zzz!!",
      ]
    case .octopus:
      return [
        "even asleep i'm eating better than you", "dream crab. obviously.",
        "zzz… still judging", "sand snack. efficient.", "unconscious, still smarter",
        "feed the sleeping menace", "zzz 🦀… noted", "don't wake me. do feed me.",
        "horizontal. still winning.", "dream insults + crab",
      ]
    }
  }

  // MARK: Play

  static func play(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "wanna play? gently!", "soft zoomies", "ball… if you want", "happy trot!",
        "come walk with me", "easy chase~", "wag game", "play bow… soft",
        "tennis? cozy version", "run a little!", "i'll wait for you", "fun… calm fun",
        "park energy (polite)", "fetch? please?", "side by side jog", "good game day",
        "tail says yes", "gentle sprint", "play then nap?", "you're it… soft",
      ]
    case .bird:
      return [
        "SKY NOW!!", "wait race— GO", "can't sit— FLY", "loop!! wait loop!!",
        "distractible flight mode", "whoosh— shiny— WHOOSH", "ADHD wings!!",
        "up up— oh leaf— UP", "chaotic soar!!", "finish later. fly NOW",
        "sparkle brain takeoff!!", "wind!! also crumbs!! also WIND", "hyperglide!!",
        "catch me if— squirrel— ME", "altitude dopamine!!", "feather rocket ASAP",
        "side quest: sky", "zoom incomplete on purpose", "FLY then forget why",
      ]
    case .octopus:
      return [
        "try to keep up", "i already won", "current. i control it.", "cute that you try",
        "race? how quaint.", "i'll go easy. maybe.", "drift circles around you",
        "your form: tragic. mine: art.", "ink optional. winning isn't.",
        "play? i prefer dominance lite", "wave says hi. i say try harder",
        "savvy swim. watch.", "bubble decoy. classic.", "you're slow. endearing.",
        "menace cardio", "i calculated your path. wrong again.",
      ]
    }
  }

  static func playAsleep(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "zzz… later, friend", "dream park only…", "nap first… soft no",
        "come back after rest…", "horizontal… but i love you",
      ]
    case .bird:
      return [
        "zzz— wait play— zzz", "dream zoom unfinished!!", "roost now. chaos later.",
        "asleep but twitching to fly", "queue the hyper. sleeping.",
      ]
    case .octopus:
      return [
        "asleep. still out of your league", "dream: beating you. again.",
        "wake me when you're interesting", "zzz… plotting", "nap. schemes loading.",
      ]
    }
  }

  // MARK: Talk / chat

  static func talk(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "hi… how's your day?", "just wanted to say hi", "you're a good human",
        "tell me something soft", "i'm listening…", "woof of solidarity",
        "quiet chat is nice", "thinking of snacks. and you.", "hey friend 💬",
        "what's on your mind?", "sit + talk = perfect", "mmm… company",
        "i like your voice", "small talk, big heart", "any news? i'm all ears",
      ]
    case .bird:
      return [
        "hey!! hey!! wait what were we— HEY", "gossip?? spill!!", "talk fast i'll interrupt",
        "so like— OH LEAF— anyway", "chat side quest!!", "tell me EVERYTHING then shiny",
        "words!! more words!!", "brain: open. mouth: open.", "chirp debate club!!",
        "wait your turn— no MY turn", "story time but chaotic", "💬💬💬",
      ]
    case .octopus:
      return [
        "speak. impress me.", "i've been waiting for material", "conversation: my arena",
        "say something. i'll improve it.", "plotting. also listening.", "hmm. continue.",
        "your thesis?", "i'll allow a chat. briefly.", "cleverness optional. try anyway.",
        "notes taken. judgment pending.", "talk. don't bore me.", "💬… annotated",
      ]
    }
  }

  // MARK: Poke / angry

  static func poke(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "ow… hey", "that was a bit much", "gentle please?", "i'm sensitive…",
        "hey… soft no", "startled…", "please don't", "sad eyes activated",
        "i still like you… but ow", "boundary… soft", "grr… little one",
        "was that needed…?", "i forgive you… mostly", "tender nose!!",
      ]
    case .bird:
      return [
        "SQUAWK— wait WHY", "rude!! also MOVE", "poke?? brain blue screen",
        "feathers EVERYWHERE thanks", "hey!! then ooh shiny— HEY", "chaos interrupt!!",
        "don't!! or do but WARN me", "ADHD crash from poke!!", "wing flap MAD",
        "i was mid-thought!!", "SQUAWK 2 electric", "personal space? never heard of her— OW",
      ]
    case .octopus:
      return [
        "bold of you", "ink. consider it.", "touch me again. see what happens.",
        "cute. suicidal. cute.", "i catalogued that offense", "menace mode: on",
        "your finger. my problem now.", "savvy tip: don't.", "i'll remember this. forever.",
        "poke the squid. classic mistake.", "hm. courage. or stupidity.",
        "you've been weighed. found poke-y.", "ink first. apology never.",
      ]
    }
  }

  // MARK: Periodic check-ins (awake only)

  static func hungry(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "a little hungry…", "food when you can?", "bowl's lonely…", "snack? softly?",
        "tummy whisper…", "treat would be nice", "dinner thoughts…", "gentle hunger",
        "i can wait… but food?", "warm meal please?", "hungry… still smiling",
        "feed when free…", "🥺 soft", "empty bowl… love you anyway",
      ]
    case .bird:
      return [
        "SEED. now. wait now.", "hungry— oh leaf— HUNGRY", "feeder EMPTY emergency!!",
        "brain needs crumbs YESTERDAY", "snack side quest!!", "can't focus. need seed.",
        "berry?? seed?? BOTH??", "stomach ADHD!!", "food shiny please!!",
        "peckish to the MAX", "refill before i forget what hunger is!!",
      ]
    case .octopus:
      return [
        "feed me. i'm thinking too hard.", "crab. or suffer my commentary.",
        "hungry makes me sharper. careful.", "snack the menace.", "🦀. don't make me ask twice.",
        "empty. like your excuses.", "calories for insults, please", "feed. then debate.",
        "i'm not begging. i'm advising.", "hunger + IQ = problem for you",
      ]
    }
  }

  /// After a long stretch at the laptop — stand up / rest eyes.
  static func stretchBreak(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "you've been sitting a while… stretch?", "soft reminder: stand up a sec",
        "eyes tired? look far away…", "walk with me? even ten steps",
        "water + stretch… kindly", "desk break… i'm coming too (spiritually)",
        "unclench those shoulders…", "window time? soft light is nice",
        "blink. really blink. good human.", "stand… wag optional",
      ]
    case .bird:
      return [
        "SIT FOREVER?? no!! STAND!!", "eyes!! look at a TREE or literally anything far",
        "stretch break SIDE QUEST!!", "you've been glued— unglue!!",
        "hop up!! flap your arms!! (i'll judge)", "blink blink BLINK campaign",
        "desk prison break!! 20 seconds!!", "water. now. then chaos resume.",
        "far-away focus. then come back. DEAL?", "legs!! remember legs??",
      ]
    case .octopus:
      return [
        "you've calcified. move.", "stand. before your spine files a complaint.",
        "eyes: soft focus on something distant. doctor's orders. mine.",
        "hydrate. stretch. then resume being wrong.",
        "ergonomics. i studied them. you're failing.",
        "blink. i counted. insufficient.", "desk ≠ habitat. migrate briefly.",
        "ten steps. i'll time you.", "posture. catastrophic. fix it.",
        "look away from the glow. i'm still judging either way.",
      ]
    }
  }

  static func lonely(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "miss you…", "sit with me?", "quiet company?", "pets when you can…",
        "i'm here… waiting softly", "come closer?", "warmth please…", "hey… friend",
        "lonely… still wagging", "your voice would help", "soft attention?",
        "beside you is enough", "gentle hello…?", "❤️…?",
      ]
    case .bird:
      return [
        "hey!! hey!! hey!!", "bored bored BORED", "attention— wait shiny— ATTENTION",
        "play?? talk?? fly?? all??", "lonely but LOUD", "come interrupt me!!",
        "social battery: chaotic empty", "need chaos buddy NOW", "tweet spam until noticed",
        "where human. where FUN.", "distract me. please. aggressively.",
      ]
    case .octopus:
      return [
        "ignore me. i dare you.", "company. optional. commentary isn't.",
        "bored. dangerous combo.", "entertain me. try.", "lonely? no. understimulated.",
        "say something clever. i'll wait.", "your silence is loud. and dull.",
        "come get roasted. free.", "i have thoughts. you should hear them.",
        "miss you. don't let it go to your head.",
      ]
    }
  }

  static func checkIn(_ species: Species) -> [String] {
    switch species {
    case .dog:
      return [
        "hi…", "just here with you", "soft woof", "you good?", "warming the floor",
        "thinking of you", "calm day", "still your dog", "quiet hello", "wag…",
        "present… gently", "good to see you", "no rush. i'm here.", "☀️ soft",
        "loyal mode", "checking in… kindly", "breathing with you", "hi friend",
      ]
    case .bird:
      return [
        "hi!! wait— hi!!", "status: vibrating", "chirp spam!!", "did you see— never mind HI",
        "brain tabs: 47", "hello then ZOOM", "still here!! already leaving!!",
        "random check-in GO", "ooh you!!", "attention fragment incoming",
        "tweet then forget why", "hyper hello!!", "existence is LOUD today",
        "pip reporting (distractible)",
      ]
    case .octopus:
      return [
        "…watching.", "hi. try harder.", "i've been thinking. you're lucky.",
        "status: smug", "hello, amateur", "drift + judge", "noted your presence",
        "savvy greeting: hm.", "don't mind me. (mind me.)", "still smarter than this room",
        "check-in. grade: pending.", "bloop. with intent.", "i allowed you a hello",
        "menace online",
      ]
    }
  }

  // MARK: Time-of-day greetings

  static func greeting(_ species: Species, _ part: Daypart) -> String {
    let pool: [String] =
      switch (species, part) {
      case (.dog, .morning):
        ["good morning… soft", "morning wag…", "rise gentle…", "warm morning", "coffee with me?"]
      case (.dog, .afternoon):
        ["afternoon… easy", "midday soft hi", "still here… calm", "sunny side with you", "quiet afternoon"]
      case (.dog, .evening):
        ["evening… cozy", "sunset wag", "soft night coming", "evening with you", "warm dusk"]
      case (.dog, .night):
        ["late… i'm with you", "night soft woof", "sleepy but near", "moontime calm", "rest when you can"]
      case (.bird, .morning):
        ["MORNING!! wait— morning!!", "sunrise brain GO", "up up already!!", "chirp alarm!!", "day = chaos start"]
      case (.bird, .afternoon):
        ["afternoon?? already??", "midday zoom!!", "hi then fly then hi", "sunny ADHD hours", "snack? sky? BOTH"]
      case (.bird, .evening):
        ["dusk but still ZOOM", "evening energy leftover!!", "sunset unfinished thoughts", "night soon— one more loop", "chaotic twilight!!"]
      case (.bird, .night):
        ["still up!! same", "night brain won't quit", "moontime fidget!!", "sleep? later. maybe.", "late night chirp spam"]
      case (.octopus, .morning):
        ["morning. impress me.", "rise. try.", "early schemes loading", "hello. already ahead.", "morning menace"]
      case (.octopus, .afternoon):
        ["afternoon. productive?", "midday judgment", "tide says try again", "hi. status: unimpressed", "savvy hours"]
      case (.octopus, .evening):
        ["evening. plot thicker.", "dusk suits me", "night plans…", "cozy? for amateurs.", "sunset smirk"]
      case (.octopus, .night):
        ["night. my shift.", "still sharper after dark", "moonlight + menace", "sleep is for the unarmed", "late thoughts. dangerous."]
      }
    return pool.randomElement()!
  }
}
