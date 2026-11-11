module SING

enum SingMode { Stealth = 0, Defense = 1, Offense = 2 }

enum SingEvent {
  ModeSwitch = 0,
  Kill = 1,
  Idle = 2
}

enum SingJobKind {
  OpenDoor = 0,
  DisableCamera = 1,
  MemoryWipe = 2,
  CrippleMovement = 3,
  DisableCyberware = 4
}

public class SingJob {
  public let id: Int32;
  public let target: wref<GameObject>;
  public let kind: SingJobKind;
}

public class SingIdleCallback extends DelayCallback {
  public func Call() -> Void {
    let sys = SingSystem.Get(GetGameInstance());
    if IsDefined(sys) {
      sys.OnIdleTick();
    };
  }
}

public class SingDefenseCallback extends DelayCallback {
  public func Call() -> Void {
    let sys = SingSystem.Get(GetGameInstance());
    if IsDefined(sys) {
      sys.OnDefenseTick();
    };
  }
}

public class SingStealthCallback extends DelayCallback {
  public func Call() -> Void {
    let sys = SingSystem.Get(GetGameInstance());
    if IsDefined(sys) {
      sys.OnStealthTick();
    };
  }
}

public class SingModeTimeoutCallback extends DelayCallback {
  public func Call() -> Void {
    let sys = SingSystem.Get(GetGameInstance());
    if IsDefined(sys) {
      sys.OnModeTimeout();
    };
  }
}

public class SingJobCallback extends DelayCallback {
  public let jobId: Int32;

  public func Call() -> Void {
    let sys = SingSystem.Get(GetGameInstance());
    if IsDefined(sys) {
      sys.CompleteJob(this.jobId);
    };
  }
}

public class SingActivationListener extends ScriptStatusEffectListener {
  private let m_player: wref<PlayerPuppet>;

  public final func Initialize(player: wref<PlayerPuppet>) -> Void {
    this.m_player = player;
    GameInstance.GetStatusEffectSystem(player.GetGame()).RegisterListener(player.GetEntityID(), this);
  }

  public func OnStatusEffectApplied(statusEffect: wref<StatusEffect_Record>) -> Void {
    if !IsDefined(statusEffect) || !IsDefined(this.m_player) {
      return;
    };
    let sys = SingSystem.Get(this.m_player.GetGame());
    if !IsDefined(sys) {
      return;
    };
    if Equals(statusEffect.GetID(), t"BaseStatusEffect.SINGStealthActivate") {
      sys.SetStealth();
    } else if Equals(statusEffect.GetID(), t"BaseStatusEffect.SINGDefenseActivate") {
      sys.SetDefense();
    };
  }

  public func OnStatusEffectRemoved(statusEffect: wref<StatusEffect_Record>) -> Void {}
}

public class SingSystem extends ScriptableSystem {

public func IsInstalled() -> Bool {
  let game = this.GetGameInstance();
  let player = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject();
  if !IsDefined(player) {
    return false;
  };
  let ts = GameInstance.GetTransactionSystem(game);

  return ts.GetItemQuantity(player, ItemID.CreateQuery(t"Items.SingShard")) > 0;
}

// true only if the S.I.N.G. quickhack is in the player's equipped cyberdeck
private func IsEquipped() -> Bool {
  let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject() as PlayerPuppet;
  if !IsDefined(player) {
    return false;
  };

  let hacks = RPGManager.GetPlayerQuickHackListWithQuality(player);
  let i = 0;
  while i < ArraySize(hacks) {
    if IsDefined(hacks[i].actionRecord) {
      let id = hacks[i].actionRecord.GetID();
      if Equals(id, t"SING.StealthHack") || Equals(id, t"SING.DefenseHack") {
        return true;
      };
    };
    i += 1;
  };
  return false;
}

  private persistent let m_mode: SingMode;
  private let m_lastSpoke: Float;
  private let m_idleRunning: Bool;
  private let m_cooldown: Float = 6.0;

  // job system state
  private let m_jobs: array<ref<SingJob>>;
  private let m_nextJobId: Int32;
  private let m_maxRange: Float = 25.0;
  private let m_defenseRunning: Bool;
  private let m_stealthRunning: Bool;
  private let m_modeActive: Bool;
  private let m_modeEndTime: Float;

  // radius scan settings
  private let m_scanRadius: Float = 20.0;
  private let m_maxJobs: Int32 = 3;

  public func IsSavable() -> Bool = true

  public static func Get(game: GameInstance) -> ref<SingSystem> {
    return GameInstance.GetScriptableSystemsContainer(game)
      .Get(n"SING.SingSystem") as SingSystem;
  }

  public func CycleMode() -> Void {
    this.m_mode = IntEnum<SingMode>((EnumInt(this.m_mode) + 1) % 3);
    this.Trigger(SingEvent.ModeSwitch, true);
    this.StartDefenseLoop();
  }

  // sets a specific mode (the three quickhacks will call these)
  public func SetMode(mode: SingMode) -> Void {
    this.m_mode = mode;
    this.m_modeActive = true;
    this.m_modeEndTime = EngineTime.ToFloat(GameInstance.GetTimeSystem(this.GetGameInstance()).GetSimTime()) + 180.0;
    this.m_defenseRunning = false;
    this.m_stealthRunning = false;
    this.ScheduleModeTimeout();
    this.Trigger(SingEvent.ModeSwitch, true);
    if Equals(mode, SingMode.Defense) {
      this.StartDefenseLoop();
    } else if Equals(mode, SingMode.Stealth) {
      this.StartStealthLoop();
    };
  }

  private func ScheduleModeTimeout() -> Void {
    GameInstance.GetDelaySystem(this.GetGameInstance())
      .DelayCallback(new SingModeTimeoutCallback(), 180.0, false);
  }

  public func OnModeTimeout() -> Void {
    let now = EngineTime.ToFloat(GameInstance.GetTimeSystem(this.GetGameInstance()).GetSimTime());
    if now < this.m_modeEndTime {
      GameInstance.GetDelaySystem(this.GetGameInstance())
        .DelayCallback(new SingModeTimeoutCallback(), this.m_modeEndTime - now, false);
      return;
    };
    this.m_modeActive = false;
    this.m_defenseRunning = false;
    this.m_stealthRunning = false;
    this.Say("Mode duration expired. Reactivation required.");
  }

  public func SetStealth() -> Void { this.SetMode(SingMode.Stealth); }
  public func SetDefense() -> Void { this.SetMode(SingMode.Defense); }
  public func SetOffense() -> Void { this.SetMode(SingMode.Offense); }

  // force = true ignores the cooldown (use for important lines)
public func Trigger(ev: SingEvent, opt force: Bool) -> Void {
  if !this.IsEquipped() {
    return;
  };

  let now = EngineTime.ToFloat(GameInstance.GetTimeSystem(this.GetGameInstance()).GetSimTime());

  if !force && this.m_lastSpoke > 0.0 && (now - this.m_lastSpoke) < this.m_cooldown {
    return;
  };

  this.m_lastSpoke = now;
  let line = this.PickLine(ev);
  if Equals(line, "") {
    return;
  };
  this.Say(line);
}
  private func PickLine(ev: SingEvent) -> String {
    let lines: array<String>;
    switch ev {
      case SingEvent.ModeSwitch:
        if Equals(this.m_mode, SingMode.Stealth) {
          lines = ["Ghost protocol engaged. We were never here."];
        } else if Equals(this.m_mode, SingMode.Defense) {
          lines = ["Shields up. Nobody touches you."];
        } else {
          lines = ["Offense online. Let's make some noise."];
        };
        break;
      case SingEvent.Kill:
        if Equals(this.m_mode, SingMode.Stealth) {
          lines = ["Clean. Quiet. I like it.", "One less problem."];
        } else if Equals(this.m_mode, SingMode.Defense) {
          lines = ["Threat down. Stay behind cover.", "Still breathing? Good."];
        } else {
          lines = ["Flatlined!", "Next one, choom.", "Boom. Beautiful."];
        };
        break;
      case SingEvent.Idle:
        lines = ["You ever think about how many cameras are watching us right now?",
                 "Quiet night. Suspiciously quiet.",
                 "I could hack a vending machine just for fun."];
        break;
    }
    if ArraySize(lines) == 0 {
      return "";
    };
    return lines[RandRange(0, ArraySize(lines))];
  }
  private func Say(text: String) -> Void {
    if !this.IsEquipped() {
      return;
    };

    let msg: SimpleScreenMessage;
    msg.isShown = true;
    msg.message = "S.I.N.G: " + text;
    msg.duration = 4.0;

    let bb = GameInstance.GetBlackboardSystem(this.GetGameInstance())
      .Get(GetAllBlackboardDefs().UI_Notifications);

    bb.SetVariant(
      GetAllBlackboardDefs().UI_Notifications.OnscreenMessage,
      ToVariant(msg),
      true
    );
  }

  // idle chatter: re-arms itself with a random delay
  public func StartIdleLoop() -> Void {
    if this.m_idleRunning {
      return;
    };
    this.m_idleRunning = true;
    this.ScheduleIdle();
  }

  private func ScheduleIdle() -> Void {
    GameInstance.GetDelaySystem(this.GetGameInstance())
      .DelayCallback(new SingIdleCallback(), RandRangeF(45.0, 120.0), false);
  }

  public func OnIdleTick() -> Void {
    this.Trigger(SingEvent.Idle, false);
    this.ScheduleIdle();
  }

  // ===== JOB SYSTEM =====

  public func StartJob(target: ref<GameObject>, kind: SingJobKind, duration: Float) -> Bool {
    if !IsDefined(target) {
      return false;
    };
    // don't start a second job on the same target
    let i = 0;
    while i < ArraySize(this.m_jobs) {
      if IsDefined(this.m_jobs[i].target) && Equals(this.m_jobs[i].target.GetEntityID(), target.GetEntityID()) {
        return false;
      };
      i += 1;
    };

    let job = new SingJob();
    job.id = this.m_nextJobId;
    job.target = target;
    job.kind = kind;
    this.m_nextJobId += 1;
    ArrayPush(this.m_jobs, job);

    let cb = new SingJobCallback();
    cb.jobId = job.id;
    GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, duration, false);

    this.Say("Hacking " + this.KindName(kind) + "...");
    return true;
  }

  public func CompleteJob(jobId: Int32) -> Void {
    let job = this.TakeJob(jobId);
    if !IsDefined(job) {
      return;
    };
    // cancel if the target is gone or you walked out of range
    if !IsDefined(job.target) || !this.InRange(job.target) {
      this.Say("Lost the connection. Moving on.");
      return;
    };

    if this.ApplyEffect(job) {
      this.Say(this.KindName(job.kind) + " done.");
    } else {
      this.Say("Already handled. Moving on.");
    };
  }

  private func TakeJob(jobId: Int32) -> ref<SingJob> {
    let i = 0;
    while i < ArraySize(this.m_jobs) {
      if this.m_jobs[i].id == jobId {
        let job = this.m_jobs[i];
        ArrayErase(this.m_jobs, i);
        return job;
      };
      i += 1;
    };
    return null;
  }

  private func InRange(target: ref<GameObject>) -> Bool {
    let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
    if !IsDefined(player) {
      return false;
    };
    return Vector4.Distance(player.GetWorldPosition(), target.GetWorldPosition()) <= this.m_maxRange;
  }

  private func KindName(kind: SingJobKind) -> String {
    switch kind {
      case SingJobKind.OpenDoor: return "door";
      case SingJobKind.DisableCamera: return "camera";
      case SingJobKind.MemoryWipe: return "mind wipe";
      case SingJobKind.CrippleMovement: return "cripple movement";
      case SingJobKind.DisableCyberware: return "cyberware malfunction";
    }
    return "target";
  }

  // test helper: starts a 3s camera job on whatever you're looking at
  public func TestJob() -> Void {
    let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
    let target = GameInstance.GetTargetingSystem(this.GetGameInstance()).GetLookAtObject(player);
    if !this.StartJob(target, SingJobKind.DisableCamera, 3.0) {
      this.Say("Nothing to hack there.");
    };
  }

  // ===== RADIUS SCAN =====

  // finds hackable things around the player and starts a job on each
  public func ScanNearby() -> Int32 {
    let game = this.GetGameInstance();
    let player = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject();

    let query = TSQ_ALL();
    query.maxDistance = this.m_scanRadius;
    query.filterObjectByDistance = true;

    let parts: array<TS_TargetPartInfo>;
    GameInstance.GetTargetingSystem(game).GetTargetParts(player, query, parts);

    let started = 0;
    let i = 0;
    while i < ArraySize(parts) && ArraySize(this.m_jobs) < this.m_maxJobs {
      let obj = TS_TargetPartInfo.GetComponent(parts[i]).GetEntity() as GameObject;
      let kind: SingJobKind;
      if IsDefined(obj) && this.ClassifyTarget(obj, kind) {
        if this.StartJob(obj, kind, 2.5) {
          started += 1;
        };
      };
      i += 1;
    };
    return started;
  }

  // decides what S.I.N.G does to a given object (returns false = ignore it)
  private func ClassifyTarget(obj: ref<GameObject>, out kind: SingJobKind) -> Bool {
    if IsDefined(obj as SurveillanceCamera) {
      if !this.IsCameraOn(obj) {
        return false;
      };
      kind = SingJobKind.DisableCamera;
      return true;
    };
    if IsDefined(obj as Door) {
      kind = SingJobKind.OpenDoor;
      return true;
    };
    return false;
  }

    // ===== DEFENSE MODE =====

  public func StartDefenseLoop() -> Void {
    if this.m_defenseRunning || !this.m_modeActive || !Equals(this.m_mode, SingMode.Defense) {
      return;
    };
    this.m_defenseRunning = true;
    this.ScheduleDefense();
  }

  public func StartStealthLoop() -> Void {
    if this.m_stealthRunning || !this.m_modeActive || !Equals(this.m_mode, SingMode.Stealth) {
      return;
    };
    this.m_stealthRunning = true;
    this.ScheduleStealth();
  }

  private func ScheduleStealth() -> Void {
    GameInstance.GetDelaySystem(this.GetGameInstance())
      .DelayCallback(new SingStealthCallback(), 2.0, false);
  }

  public func OnStealthTick() -> Void {
    if !this.m_modeActive || !Equals(this.m_mode, SingMode.Stealth) {
      this.m_stealthRunning = false;
      return;
    };
    this.ScanNearby();
    this.ScheduleStealth();
  }

  private func ScheduleDefense() -> Void {
    GameInstance.GetDelaySystem(this.GetGameInstance())
      .DelayCallback(new SingDefenseCallback(), 2.0, false);
  }

  public func OnDefenseTick() -> Void {
    if !this.m_modeActive || !Equals(this.m_mode, SingMode.Defense) {
      this.m_defenseRunning = false;
      return;
    };
    this.ScanHostiles();
    this.ScheduleDefense();
  }

  // radius scan for hostile NPCs, starts a defensive hack on each
  public func ScanHostiles() -> Int32 {
    let game = this.GetGameInstance();
    let player = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject();

    let query = TSQ_NPC();
    query.maxDistance = this.m_scanRadius;
    query.filterObjectByDistance = true;

    let parts: array<TS_TargetPartInfo>;
    GameInstance.GetTargetingSystem(game).GetTargetParts(player, query, parts);

    let started = 0;
    let i = 0;
    while i < ArraySize(parts) && ArraySize(this.m_jobs) < this.m_maxJobs {
      let npc = TS_TargetPartInfo.GetComponent(parts[i]).GetEntity() as NPCPuppet;
      if IsDefined(npc) && this.IsHostileNPC(npc, player) {
        let kind: SingJobKind;
        if this.PickDefenseHack(npc, kind) {
          if this.StartJob(npc, kind, 1.0) {
            started += 1;
          };
        };
      };
      i += 1;
    };
    return started;
  }

  private func IsHostileNPC(npc: ref<NPCPuppet>, player: ref<GameObject>) -> Bool {
    if !ScriptedPuppet.IsActive(npc) {
      return false;
    };
    return Equals(npc.GetAttitudeTowards(player), EAIAttitude.AIA_Hostile) && npc.IsAggressive();
  }

  // cripple first, then cyberware malfunction; false = nothing left to apply
private func PickDefenseHack(npc: ref<NPCPuppet>, out kind: SingJobKind) -> Bool {
    if !this.HasEffect(npc, this.CrippleId()) {
      kind = SingJobKind.CrippleMovement;
      return true;
    };
    if !this.HasEffect(npc, this.MalfunctionId()) {
      kind = SingJobKind.DisableCyberware;
      return true;
    };
    return false;
}
  // status effect record names, change here if the Tweak Browser shows different ones
  private func CrippleId() -> TweakDBID { return t"BaseStatusEffect.CrippleMovement"; }
  private func MalfunctionId() -> TweakDBID { return t"BaseStatusEffect.CyberwareMalfunction"; }

  // ===== EFFECTS =====

  // true only if the device exists and is currently powered on
  private func IsCameraOn(obj: ref<GameObject>) -> Bool {
    let device = obj as Device;
    if !IsDefined(device) {
      return false;
    };
    return device.GetDevicePS().IsON();
  }

  // returns true if an effect was actually applied
  private func ApplyEffect(job: ref<SingJob>) -> Bool {
    switch job.kind {
      case SingJobKind.DisableCamera:
        if !this.IsCameraOn(job.target) {
          return false;
        };
        this.RunDeviceAction(job.target, n"ToggleON");
        return true;
      case SingJobKind.OpenDoor:
        this.RunDeviceAction(job.target, n"ToggleOpen");
        return true;
      case SingJobKind.CrippleMovement:
        return this.ApplyStatus(job.target, this.CrippleId());
      case SingJobKind.DisableCyberware:
        return this.ApplyStatus(job.target, this.MalfunctionId());
    }
    return false;
  }

  private func ApplyStatus(target: ref<GameObject>, id: TweakDBID) -> Bool {
    if this.HasEffect(target, id) {
      return false;
    };

    let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
    return StatusEffectHelper.ApplyStatusEffect(target, id, player.GetEntityID());
  }

  private func HasEffect(target: ref<GameObject>, id: TweakDBID) -> Bool {
    return GameInstance.GetStatusEffectSystem(this.GetGameInstance()).HasStatusEffect(target.GetEntityID(), id);
  }

  // runs a device action by name, the same route quickhacks use
  private func RunDeviceAction(target: ref<GameObject>, actionName: CName) -> Void {
    let device = target as Device;
    if !IsDefined(device) {
      return;
    };
    let ps = device.GetDevicePS();
    let action = ps.GetActionByName(actionName) as ScriptableDeviceAction;
    if IsDefined(action) {
      ps.ExecutePSAction(action, ps);
    } else {
      this.Say("No action named " + NameToString(actionName));
    };
  }
}

// === TRIGGER HOOKS ===

// Kill trigger: fires when the player kills an NPC
@wrapMethod(NPCPuppet)
protected cb func OnDeath(evt: ref<gameDeathEvent>) -> Bool {
  let result = wrappedMethod(evt);
  if IsDefined(evt.instigator) && evt.instigator.IsPlayer() {
    let sys = SingSystem.Get(this.GetGame());
    if IsDefined(sys) {
      sys.Trigger(SingEvent.Kill, false);
    };
  };
  return result;
}

// Start the idle loop once the player spawns
@addField(PlayerPuppet)
private let m_singActivationListener: ref<SingActivationListener>;

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  let result = wrappedMethod();
  let sys = SingSystem.Get(this.GetGame());
  if IsDefined(sys) {
    sys.StartIdleLoop();
  };
  this.m_singActivationListener = new SingActivationListener();
  this.m_singActivationListener.Initialize(this);
  return result;
}
