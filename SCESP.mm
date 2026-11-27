// SCESP.mm v5.9 — StandChillow (Unity IL2CPP, iOS arm64), ESP for offline bot matches
//
// Box / skeleton / chams / box fill / health bar, enemies only (teammates optional), settings panel.
// Tap the small "ESP" plate (top-left) to open/close the settings panel.
//
// - everything is resolved by class/method name at runtime through the exported il2cpp API
// - team comes from the PlayerController fields typed Core.Team; "me" is the character at the camera
// - skeleton = real bones of each character's biggest SkinnedMeshRenderer, parent->child lines
// - chams = swaps the enemy's materials for an unlit colour material that ignores depth
//   (needs a built-in shader that exists in the build; the panel shows which one it found)
// - health bar = vertical bar left of the box. The health field is obfuscated, so it is LEARNED:
//   panel "Learn health" -> hit one bot once -> tap again. The field that dropped on exactly one
//   character (and stayed put on all others) is stored and read every tick.
// - armor bar = blue vertical bar right of the box, from PlayerController.odf() (armor int); the gold dot above it is the
//   odg() armor flag (v24 reverse notes: HUD reads ode/odf/odg together). Meaning of odg() is by data flow, not proven.
// - bunny hop (v5.6): flips the game's own PlayerCheatParameters._bhop path on the local player via
//   MovementController.ouk(bool) (state +0x6F; physics branch uses BhopSpeedStep/ResetTime/MaxSpeed). Offline bot matches only.
//   v5.7: full bhop settings (Misc > Movement): "Custom values" + Speed step / Max speed / Reset time sliders. The three floats are
//   found at runtime by field name (no hardcoded offsets); sliders are multipliers of the game's own value, so units never matter.
//   Untick Custom values (or Bunny hop) and the game's original values are written back.
// - custom hands / viewmodel (v5.8, Misc > Viewmodel): the game has its own CustomViewModel settings (PositionOffset, RotationOffset,
//   AdditiveFov inside GameSettings). The live GameSettings object is found at runtime (object-graph walk + static fields of *Settings*
//   classes), our values are written into it BY FIELD NAME and PlayerController.obu(GameSettings) is called to re-apply. Originals are
//   saved and put back when the toggle goes off. "Hands type"/"FOV type" overwrite the two (obfuscated) enums; -1 = leave alone. The panel
//   prints the enum members it can read, so you can see which number is which.
// - stretch (v5.8, Misc > Stretch): Screen.SetResolution(height*aspect, height). iOS scales the smaller backbuffer to the whole screen.
//   The ESP overlay keeps lining up because it maps world->screen with the current Screen.width/height every tick.
// - no spread (v5.9, Misc > Performance): zeroes the weapon accuracy/dispersion data of every live GunParameters (names taken from the static
//   metadata dump): _accuracyMultOnJump/_accuracyMultOnCrouch/_accuracyAimMult/_accuracyAimMultOnCrouch (floats) and the curves
//   _accuracyAdditiveCurve, _additiveNoAimDispertionCurve, _recoilParameters.relativeDispertionCurve (swapped for AnimationCurve.Constant(0,1,0)).
//   Originals are saved and put back when the toggle goes off. It only runs while every other character in the scene is a bot
//   (offline bot match); the moment a non-bot character shows up everything is restored.
// - hot path uses direct method-pointer calls; drawing is 30 fps, scan about once a second
//
// Not compiled or run on a device by me. If something misbehaves, the panel's status line says where.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <ctype.h>
#include <string>
#include <algorithm>
#include <math.h>
// ---- SilentAimCore (inlined, no separate header needed) ----

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace silent_aim {

struct Vec3 {
    float x{0.0f};
    float y{0.0f};
    float z{0.0f};
};

inline Vec3 operator-(const Vec3& a, const Vec3& b) noexcept {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

inline Vec3 operator+(const Vec3& a, const Vec3& b) noexcept {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

inline Vec3 operator*(const Vec3& v, float s) noexcept {
    return {v.x * s, v.y * s, v.z * s};
}

inline float Dot(const Vec3& a, const Vec3& b) noexcept {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline float LengthSquared(const Vec3& v) noexcept {
    return Dot(v, v);
}

inline float Length(const Vec3& v) noexcept {
    return std::sqrt(LengthSquared(v));
}

inline bool IsFinite(const Vec3& v) noexcept {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

inline bool Normalize(const Vec3& value, Vec3& out) noexcept {
    if (!IsFinite(value)) {
        return false;
    }

    const float lengthSq = LengthSquared(value);
    if (!std::isfinite(lengthSq) || lengthSq <= 1.0e-8f) {
        return false;
    }

    out = value * (1.0f / std::sqrt(lengthSq));
    return IsFinite(out);
}

struct Target {
    std::uintptr_t entity{0}; // Указатель/ID сущности, который передаст твой адаптер.
    Vec3 aimPoint{};          // Уже выбранная точка: голова, грудь и т. п.
    bool alive{false};
    bool enemy{false};
    bool visible{false};
};

struct ShotContext {
    Vec3 cameraOrigin{}; // Позиция камеры — для проверки FOV.
    Vec3 shotOrigin{};   // Реальная точка вылета снаряда/начала трассировки.
    Vec3 viewForward{};  // Направление взгляда камеры ДО выстрела.
    bool active{false};  // Сюда передаётся состояние кнопки активации.
};

struct Settings {
    bool enabled{true};
    bool requireVisible{true};
    float maxFovDegrees{8.0f};
    float maxDistance{0.0f}; // 0 = без ограничения дистанции.
};

struct ShotSolution {
    std::uintptr_t entity{0};
    std::size_t targetIndex{0};
    Vec3 aimPoint{};
    Vec3 direction{}; // Нормализованное направление для параметра выстрела/трассировки.
    float angularErrorDegrees{0.0f};
    float distance{0.0f};
};

// Возвращает true, если найден допустимый противник.
// Функция не меняет углы камеры: она только рассчитывает направление конкретного выстрела.
inline bool BuildSilentShot(
    const ShotContext& shot,
    const std::vector<Target>& targets,
    const Settings& settings,
    ShotSolution& out) noexcept {

    if (!settings.enabled || !shot.active || targets.empty()) {
        return false;
    }

    if (!IsFinite(shot.cameraOrigin) || !IsFinite(shot.shotOrigin) ||
        !std::isfinite(settings.maxFovDegrees) ||
        !std::isfinite(settings.maxDistance)) {
        return false;
    }

    Vec3 viewForward{};
    if (!Normalize(shot.viewForward, viewForward)) {
        return false;
    }

    const float fov = std::clamp(settings.maxFovDegrees, 0.0f, 180.0f);
    const float minDot = std::cos(fov * 0.01745329251994329577f);
    const float maxDistance = std::max(0.0f, settings.maxDistance);

    bool found = false;
    float bestDot = -std::numeric_limits<float>::infinity();
    float bestDistance = std::numeric_limits<float>::infinity();
    ShotSolution best{};

    for (std::size_t i = 0; i < targets.size(); ++i) {
        const Target& target = targets[i];
        if (!target.alive || !target.enemy ||
            (settings.requireVisible && !target.visible) ||
            !IsFinite(target.aimPoint)) {
            continue;
        }

        Vec3 toTarget{};
        if (!Normalize(target.aimPoint - shot.cameraOrigin, toTarget)) {
            continue;
        }

        const float aimDot = std::clamp(Dot(viewForward, toTarget), -1.0f, 1.0f);
        if (aimDot < minDot) {
            continue;
        }

        const float distance = Length(target.aimPoint - shot.cameraOrigin);
        if (!std::isfinite(distance) ||
            (maxDistance > 0.0f && distance > maxDistance)) {
            continue;
        }

        // Приоритет — минимальное отклонение от направления взгляда;
        // при равном отклонении выбирается более близкая цель.
        if (found && aimDot < bestDot - 1.0e-6f) {
            continue;
        }
        if (found && std::fabs(aimDot - bestDot) <= 1.0e-6f &&
            distance >= bestDistance) {
            continue;
        }

        Vec3 shotDirection{};
        if (!Normalize(target.aimPoint - shot.shotOrigin, shotDirection)) {
            continue;
        }

        best.entity = target.entity;
        best.targetIndex = i;
        best.aimPoint = target.aimPoint;
        best.direction = shotDirection;
        best.angularErrorDegrees = std::acos(aimDot) * 57.295779513082320876f;
        best.distance = distance;
        bestDot = aimDot;
        bestDistance = distance;
        found = true;
    }

    if (!found) {
        return false;
    }

    out = best;
    return true;
}

} // namespace silent_aim

// ---- end SilentAimCore ----

// ---- config ----------------------------------------------------------------------------
static const char *kGameImage = "Chillow.StandChillow.Client.dll";
struct Target { const char *ns; const char *name; };
static const Target kTargets[] = {
    {"Chillow.StandChillow.Player", "PlayerController"},
    {"Chillow.StandChillow.Player", "CharacterPlayer"},
    {"Chillow.StandChillow.Bots.Core", "BotPlayerController"},
};
static const int   kN = sizeof(kTargets) / sizeof(kTargets[0]);
static const char *kTeamType = "Chillow.StandChillow.Core.Team";   // None=0 Tr=1 Ct=2 Spectator=3
static const float kSelfRadius = 0.7f;
static const int   kRefreshTicks = 30;
static const char *kChamShaders[] = { "Hidden/Internal-Colored", "GUI/Text Shader", "UI/Default", "Sprites/Default" };
// bones whose lowercase name contains any of these are never drawn and never count for the box
static const char *kBoneSkip[] = { "root", "ik", "target", "pole", "weapon", "gun" };
// bones further than this from the player pivot are junk (IK helpers, world-origin bones)
static const float kBelowFeet = 0.3f, kMaxReach = 2.0f;
static const float kAimFov = 18.0f;   // degrees: aim lock only grabs targets this close to the crosshair

// ---- aim body-part selection ------------------------------------------------------------
enum AimPart : int {
    kAimHead = 0, kAimNeck, kAimChest, kAimStomach,
    kAimPelvis, kAimArm, kAimLeg, kAimFoot, kAimPartCount
};
static int g_selectedAimPart = kAimHead;
static NSString *aimPartTitle(int part) {
    switch (part) {
        case kAimHead: return @"Head";
        case kAimNeck: return @"Neck";
        case kAimChest: return @"Chest";
        case kAimStomach: return @"Stomach";
        case kAimPelvis: return @"Pelvis";
        case kAimArm: return @"Arms";
        case kAimLeg: return @"Legs";
        case kAimFoot: return @"Feet";
        default: return @"Head";
    }
}

// ---- settings --------------------------------------------------------------------------
struct Settings {
    bool on = true, box = true, skel = true, chams = false, fill = false, team = false, lowcpu = false, noocc = true, aim = false, hp = true, hdot = true;
    bool bhop = false;      // enable the game's built-in bunny-hop movement flag on the local player
    bool bhopCustom = false;                                  // apply the multipliers below to the game's bhop parameters
    float bhopStep = 1.0f, bhopMax = 1.0f, bhopReset = 1.0f;  // multipliers: speed step / max speed / reset time
    int color = 0;          // 0..6 = preset swatch, -1 = custom colour from the picker (hue/sat/val below)
    float ch = 0.0f, cs = 0.85f, cv = 1.0f;
    float lw = 1.5f;
    float head = 1.8f;
    float fov = 45.0f;      // aim capture cone, degrees
    float aimSpeed = 14.0f; // aim smoothing: higher = snappier (1/s)
    bool drawFov = true;    // draw the aim capture outline on screen
    bool dmg = true;        // floating damage numbers
    bool dmgMine = true;    // damage numbers only for hits taken while the target is under my crosshair
    bool armor = true;      // armor bar (right of the box) + armor-flag marker, from PlayerController.odf()/odg()
    bool wep = true;        // weapon name under the box
    bool vm = false;        // custom hands position (game's CustomViewModel)
    float vmv[9] = { 0, 0, 0, 0, 0, 0, 0, -1, -1 };   // posX posY posZ rotX rotY rotZ addFov handsType(-1=keep) fovType(-1=keep)
    bool nospread = false;  // zero weapon spread/dispersion data (offline bot matches only)
    bool silent = false;    // silent aim: rewrites the direction of each shot (offline bot matches only)
    float silentFov = 8.0f; // silent aim capture cone, degrees
    bool stretch = false;   // stretched resolution
    float stretchAspect = 1.3333f;                      // width/height of the render target
};
static Settings g_set;
static bool g_dirty = true;

static UIColor *colorFor(int i, CGFloat a) {
    if (i < 0) return [UIColor colorWithHue:g_set.ch saturation:g_set.cs brightness:g_set.cv alpha:a];
    switch (i) {
        case 0: return [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:a];
        case 1: return [UIColor colorWithRed:0.1 green:1 blue:0.2 alpha:a];
        case 2: return [UIColor colorWithRed:0.1 green:0.9 blue:1 alpha:a];
        case 3: return [UIColor colorWithRed:1 green:0.9 blue:0.1 alpha:a];
        case 4: return [UIColor colorWithRed:1 green:1 blue:1 alpha:a];
        case 5: return [UIColor colorWithRed:1 green:0.2 blue:1 alpha:a];
        default: return [UIColor colorWithRed:1 green:0.55 blue:0.1 alpha:a];
    }
}
static void saveSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:g_set.on forKey:@"scesp_on"];       [d setBool:g_set.box forKey:@"scesp_box"];
    [d setBool:g_set.skel forKey:@"scesp_skel"];   [d setBool:g_set.chams forKey:@"scesp_chams"];
    [d setBool:g_set.fill forKey:@"scesp_fill"];   [d setBool:g_set.team forKey:@"scesp_team"];
    [d setBool:g_set.lowcpu forKey:@"scesp_low"];
    [d setBool:g_set.noocc forKey:@"scesp_noocc"];
    [d setBool:g_set.hp forKey:@"scesp_hp"];
    [d setBool:g_set.hdot forKey:@"scesp_hdot"];
    [d setBool:g_set.nospread forKey:@"scesp_nsp"];
    [d setBool:g_set.silent forKey:@"scesp_silent"]; [d setFloat:g_set.silentFov forKey:@"scesp_silfov"];
    [d setBool:g_set.bhop forKey:@"scesp_bhop"];
    [d setBool:g_set.bhopCustom forKey:@"scesp_bhcus"];
    [d setFloat:g_set.bhopStep forKey:@"scesp_bhstep"]; [d setFloat:g_set.bhopMax forKey:@"scesp_bhmax"]; [d setFloat:g_set.bhopReset forKey:@"scesp_bhrst"];
    [d setInteger:g_set.color forKey:@"scesp_color"];
    [d setFloat:g_set.ch forKey:@"scesp_ch"]; [d setFloat:g_set.cs forKey:@"scesp_cs"]; [d setFloat:g_set.cv forKey:@"scesp_cv"];
    [d setFloat:g_set.lw forKey:@"scesp_lw"];      [d setFloat:g_set.head forKey:@"scesp_head"];
    [d setFloat:g_set.fov forKey:@"scesp_fov"];
    [d setFloat:g_set.aimSpeed forKey:@"scesp_aspd"];
    [d setBool:g_set.drawFov forKey:@"scesp_dfov"];
    [d setBool:g_set.dmg forKey:@"scesp_dmgnum"];
    [d setBool:g_set.dmgMine forKey:@"scesp_dmgmine"];
    [d setBool:g_set.armor forKey:@"scesp_armor"];
    [d setBool:g_set.wep forKey:@"scesp_wep"];
    [d setInteger:g_selectedAimPart forKey:@"scesp_aim_part"];
    [d setBool:g_set.vm forKey:@"scesp_vm"];
    for (int i = 0; i < 9; i++) [d setFloat:g_set.vmv[i] forKey:[NSString stringWithFormat:@"scesp_vm%d", i]];
    [d setBool:g_set.stretch forKey:@"scesp_st"];
    [d setFloat:g_set.stretchAspect forKey:@"scesp_stasp"];
}
static void loadSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d objectForKey:@"scesp_on"]) return;
    g_set.on = [d boolForKey:@"scesp_on"];         g_set.box = [d boolForKey:@"scesp_box"];
    g_set.skel = [d boolForKey:@"scesp_skel"];     g_set.chams = [d boolForKey:@"scesp_chams"];
    g_set.fill = [d boolForKey:@"scesp_fill"];     g_set.team = [d boolForKey:@"scesp_team"];
    g_set.lowcpu = [d boolForKey:@"scesp_low"];
    g_set.noocc = [d objectForKey:@"scesp_noocc"] ? [d boolForKey:@"scesp_noocc"] : true;
    g_set.hdot = [d objectForKey:@"scesp_hdot"] ? [d boolForKey:@"scesp_hdot"] : true;
    g_set.nospread = [d boolForKey:@"scesp_nsp"];
    g_set.bhop = [d boolForKey:@"scesp_bhop"];
    g_set.bhopCustom = [d boolForKey:@"scesp_bhcus"];
    g_set.bhopStep = [d floatForKey:@"scesp_bhstep"];   if (g_set.bhopStep  < 0.1f) g_set.bhopStep  = 1.0f;
    g_set.bhopMax = [d floatForKey:@"scesp_bhmax"];     if (g_set.bhopMax   < 0.1f) g_set.bhopMax   = 1.0f;
    g_set.bhopReset = [d floatForKey:@"scesp_bhrst"];   if (g_set.bhopReset < 0.1f) g_set.bhopReset = 1.0f;
    g_set.hp = [d objectForKey:@"scesp_hp"] ? [d boolForKey:@"scesp_hp"] : true;
    g_set.color = (int)[d integerForKey:@"scesp_color"];
    if ([d objectForKey:@"scesp_ch"]) {
        g_set.ch = [d floatForKey:@"scesp_ch"]; g_set.cs = [d floatForKey:@"scesp_cs"]; g_set.cv = [d floatForKey:@"scesp_cv"];
    } else {                                                       // first run with the picker: start from the saved preset
        CGFloat h = 0, sa = 0.85, v = 1, al = 1;
        if ([colorFor(g_set.color < 0 ? 0 : g_set.color, 1) getHue:&h saturation:&sa brightness:&v alpha:&al]) { g_set.ch = h; g_set.cs = sa; g_set.cv = v; }
    }
    g_set.lw = [d floatForKey:@"scesp_lw"];        g_set.head = [d floatForKey:@"scesp_head"];
    if (g_set.lw < 0.5f) g_set.lw = 1.5f;
    if (g_set.head < 1.0f) g_set.head = 1.8f;
    g_set.fov = [d floatForKey:@"scesp_fov"]; if (g_set.fov < 5.0f) g_set.fov = 45.0f;
    g_set.aimSpeed = [d floatForKey:@"scesp_aspd"]; if (g_set.aimSpeed < 2.0f) g_set.aimSpeed = 14.0f;
    g_set.drawFov = [d objectForKey:@"scesp_dfov"] ? [d boolForKey:@"scesp_dfov"] : true;
    g_set.dmg = [d objectForKey:@"scesp_dmgnum"] ? [d boolForKey:@"scesp_dmgnum"] : true;
    g_set.dmgMine = [d objectForKey:@"scesp_dmgmine"] ? [d boolForKey:@"scesp_dmgmine"] : true;
    g_set.armor = [d objectForKey:@"scesp_armor"] ? [d boolForKey:@"scesp_armor"] : true;
    g_set.wep = [d objectForKey:@"scesp_wep"] ? [d boolForKey:@"scesp_wep"] : true;
    g_selectedAimPart = (int)[d integerForKey:@"scesp_aim_part"];
    if (g_selectedAimPart < 0 || g_selectedAimPart >= kAimPartCount) g_selectedAimPart = kAimHead;
    g_set.vm = [d boolForKey:@"scesp_vm"];
    g_set.silent = [d boolForKey:@"scesp_silent"];
    if ([d objectForKey:@"scesp_silfov"]) g_set.silentFov = [d floatForKey:@"scesp_silfov"];
    if (g_set.silentFov < 1.0f || g_set.silentFov > 60.0f) g_set.silentFov = 8.0f;
    for (int i = 0; i < 9; i++) {
        NSString *key = [NSString stringWithFormat:@"scesp_vm%d", i];
        if ([d objectForKey:key]) g_set.vmv[i] = [d floatForKey:key];
    }
    g_set.stretch = [d boolForKey:@"scesp_st"];
    if ([d objectForKey:@"scesp_stasp"]) g_set.stretchAspect = [d floatForKey:@"scesp_stasp"];
    if (g_set.stretchAspect < 1.0f || g_set.stretchAspect > 2.5f) g_set.stretchAspect = 1.3333f;
}

// ---- il2cpp API ------------------------------------------------------------------------
typedef void *(*fn_domain_get)(void);
typedef void **(*fn_domain_get_assemblies)(void *, size_t *);
typedef void *(*fn_assembly_get_image)(void *);
typedef const char *(*fn_image_get_name)(void *);
typedef void *(*fn_class_from_name)(void *, const char *, const char *);
typedef void *(*fn_class_get_method)(void *, const char *, int);
typedef void *(*fn_runtime_invoke)(void *, void *, void **, void **);
typedef void *(*fn_class_get_type)(void *);
typedef void *(*fn_type_get_object)(void *);
typedef uint32_t (*fn_gchandle_new)(void *, int);
typedef void *(*fn_gchandle_get)(uint32_t);
typedef void (*fn_gchandle_free)(uint32_t);
typedef void *(*fn_class_get_fields)(void *, void **);
typedef void *(*fn_class_get_methods)(void *, void **);
typedef void *(*fn_class_get_parent)(void *);
typedef void *(*fn_field_get_type)(void *);
typedef int (*fn_field_get_offset)(void *);
typedef int (*fn_field_get_flags)(void *);
typedef char *(*fn_type_get_name)(void *);
typedef const char *(*fn_method_get_name)(void *);
typedef uint32_t (*fn_method_param_count)(void *);
typedef void *(*fn_method_get_param)(void *, uint32_t);
typedef void *(*fn_string_new)(const char *);
typedef void *(*fn_object_new)(void *);
typedef void *(*fn_array_new)(void *, uintptr_t);
typedef const uint16_t *(*fn_string_chars)(void *);
typedef int (*fn_string_length)(void *);
typedef void *(*fn_class_from_type)(void *);
typedef bool (*fn_class_is_vt)(void *);
typedef const char *(*fn_field_get_name)(void *);

static fn_domain_get il2_domain_get;
static fn_domain_get_assemblies il2_get_assemblies;
static fn_assembly_get_image il2_asm_image;
static fn_image_get_name il2_image_name;
static fn_class_from_name il2_class_from_name;
static fn_class_get_method il2_get_method;
static fn_runtime_invoke il2_invoke;
static fn_class_get_type il2_class_type;
static fn_type_get_object il2_type_object;
static fn_gchandle_new il2_gc_new;
static fn_gchandle_get il2_gc_get;
static fn_gchandle_free il2_gc_free;
static fn_class_get_fields il2_class_fields;
static fn_class_get_methods il2_class_methods;
static fn_class_get_parent il2_class_parent;
static fn_field_get_type il2_field_type;
static fn_field_get_offset il2_field_offset;
static fn_field_get_flags il2_field_flags;
static fn_type_get_name il2_type_name;
static fn_method_get_name il2_method_name;
static fn_method_param_count il2_method_pcount;
static fn_method_get_param il2_method_param;
static fn_string_new il2_string_new;
static fn_object_new il2_object_new;
static fn_array_new il2_array_new;
static fn_string_chars il2_str_chars;
static fn_string_length il2_str_len;
static fn_class_from_type il2_class_from_type;
static fn_class_is_vt il2_class_is_vt;
static fn_field_get_name il2_field_name;
// engine icalls: exist in the native engine even when the managed wrapper is stripped from the build
typedef void *(*fn_resolve_icall)(const char *);
typedef void (*ic_set_bool)(void *, bool);
typedef bool (*ic_get_bool)(void *);
static fn_resolve_icall il2_resolve_icall;
static ic_set_bool ic_cam_set_occ;
static ic_get_bool ic_cam_get_occ, ic_rend_vis;
static ic_set_bool ic_rend_set_allow;

struct V3 { float x, y, z; };
struct Col { float r, g, b, a; };

typedef void *(*d_get_main)(void *mi);
typedef void *(*d_obj_get)(void *self, void *mi);
typedef V3 (*d_get_position)(void *self, void *mi);
typedef V3 (*d_w2s)(void *self, V3 p, void *mi);
typedef int (*d_screen)(void *mi);

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (!p) NSLog(@"[SCESP] missing symbol %s", n);
    return p;
}

static bool loadApi() {
    il2_domain_get      = (fn_domain_get)sym("il2cpp_domain_get");
    il2_get_assemblies  = (fn_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    il2_asm_image       = (fn_assembly_get_image)sym("il2cpp_assembly_get_image");
    il2_image_name      = (fn_image_get_name)sym("il2cpp_image_get_name");
    il2_class_from_name = (fn_class_from_name)sym("il2cpp_class_from_name");
    il2_get_method      = (fn_class_get_method)sym("il2cpp_class_get_method_from_name");
    il2_invoke          = (fn_runtime_invoke)sym("il2cpp_runtime_invoke");
    il2_class_type      = (fn_class_get_type)sym("il2cpp_class_get_type");
    il2_type_object     = (fn_type_get_object)sym("il2cpp_type_get_object");
    il2_gc_new          = (fn_gchandle_new)sym("il2cpp_gchandle_new");
    il2_gc_get          = (fn_gchandle_get)sym("il2cpp_gchandle_get_target");
    il2_gc_free         = (fn_gchandle_free)sym("il2cpp_gchandle_free");
    il2_class_fields    = (fn_class_get_fields)sym("il2cpp_class_get_fields");
    il2_class_methods   = (fn_class_get_methods)sym("il2cpp_class_get_methods");
    il2_class_parent    = (fn_class_get_parent)sym("il2cpp_class_get_parent");
    il2_field_type      = (fn_field_get_type)sym("il2cpp_field_get_type");
    il2_field_offset    = (fn_field_get_offset)sym("il2cpp_field_get_offset");
    il2_field_flags     = (fn_field_get_flags)sym("il2cpp_field_get_flags");
    il2_type_name       = (fn_type_get_name)sym("il2cpp_type_get_name");
    il2_method_name     = (fn_method_get_name)sym("il2cpp_method_get_name");
    il2_method_pcount   = (fn_method_param_count)sym("il2cpp_method_get_param_count");
    il2_method_param    = (fn_method_get_param)sym("il2cpp_method_get_param");
    il2_string_new      = (fn_string_new)sym("il2cpp_string_new");
    il2_object_new      = (fn_object_new)sym("il2cpp_object_new");
    il2_array_new       = (fn_array_new)sym("il2cpp_array_new");
    il2_str_chars       = (fn_string_chars)sym("il2cpp_string_chars");     // optional (bone names)
    il2_str_len         = (fn_string_length)sym("il2cpp_string_length");   // optional
    il2_class_from_type = (fn_class_from_type)sym("il2cpp_class_from_type");   // optional (aim learning)
    il2_class_is_vt     = (fn_class_is_vt)sym("il2cpp_class_is_valuetype");    // optional
    il2_field_name      = (fn_field_get_name)sym("il2cpp_field_get_name");         // optional (diagnostics)
    il2_resolve_icall   = (fn_resolve_icall)sym("il2cpp_resolve_icall");          // optional
    return il2_domain_get && il2_get_assemblies && il2_asm_image && il2_image_name &&
           il2_class_from_name && il2_get_method && il2_invoke && il2_class_type &&
           il2_type_object && il2_gc_new && il2_gc_get && il2_gc_free && il2_class_fields &&
           il2_class_methods && il2_class_parent && il2_field_type && il2_field_offset &&
           il2_field_flags && il2_type_name && il2_method_name && il2_method_pcount &&
           il2_method_param && il2_string_new && il2_object_new && il2_array_new;
}

static void *findImage(const char *name) {
    size_t n = 0;
    void **asms = il2_get_assemblies(il2_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2_asm_image(asms[i]);
        if (img && strcmp(il2_image_name(img), name) == 0) return img;
    }
    return nullptr;
}

// method lookup that tells overloads apart by their first parameter's type name
static void *findMethod(void *klass, const char *name, uint32_t argc, const char *p0) {
    void *iter = nullptr, *m;
    while ((m = il2_class_methods(klass, &iter))) {
        if (strcmp(il2_method_name(m), name) != 0 || il2_method_pcount(m) != argc) continue;
        if (!p0) return m;
        const char *tn = il2_type_name(il2_method_param(m, 0));
        if (tn && strcmp(tn, p0) == 0) return m;
    }
    return nullptr;
}

static void *inv(void *mi, void *obj, void **args) {
    if (!mi) return nullptr;
    void *exc = nullptr;
    void *r = il2_invoke(mi, obj, args, &exc);
    return exc ? nullptr : r;
}

// ---- resolved state --------------------------------------------------------------------
// health may live on a sibling component, not on PlayerController: root 0 = the player class, others below
struct HpRoot { const char *ns, *name; };
static const HpRoot kHpRootDefs[] = {
    { nullptr, nullptr },
    { "Chillow.StandChillow.Player.Hit", "PlayerHitController" },
    { "Chillow.StandChillow.Player.Hit", "HitController" },
    { "Chillow.StandChillow.Player.Hit", "DummyHitController" },
    { "Chillow.StandChillow.Player", "NetworkController" },
    { "Chillow.StandChillow.Player", "CharacterPlayer" },
};
static const int kHpRoots = 6;
static void *k_hpRoot[kHpRoots];
static bool g_hpRoots = false;          // rescan() also collects the root components per player
static void *k_targets[8];
// offsets from the static dump (StandChillow 2.07): PlayerController fields + HP getter
static const int kOffBot = 0xC8;      // PlayerController.<cfip> : BotPlayerController  (non-null = bot)
static const int kOffAim = 0xD0;      // PlayerController.<cfiq> : AimController         (back-reference at AimController +0xC8)
static void *mi_hp;                   // PlayerController.ode() -> int  current HP
static void *mi_armor, *mi_helm;      // PlayerController.odf() -> int armor value, odg() -> bool armor flag (v24 notes: HUD reads both next to HP)
static int g_nBots = 0;
static size_t g_counts[8];
static int g_active = -1;
static std::vector<int> g_teamOffsets;
static int g_teamField = -1;

static void *k_smr, *k_material, *k_shader;
// chams through a CommandBuffer on the camera (draws regardless of culling / occlusion, like the game's own HighlightEffect)
static void *k_cmdbuf, *mi_cb_ctor, *mi_cb_clear, *mi_cb_draw2, *mi_cb_draw3, *mi_cam_addcb, *mi_cam_rmcb;
static bool g_cbActive = false;
static void *mi_find, *mi_get_bones, *mi_get_smats, *mi_set_smats, *mi_find_shader, *mi_mat_ctor;
static void *mi_set_color, *mi_set_queue, *mi_setint, *mi_setglobal, *mi_get_name, *mi_hasprop;
static void *k_animator, *k_occsys;
static void *mi_anim_cull, *mi_beh_enabled, *mi_smr_offscreen, *mi_rend_enabled, *mi_cam_occ;
static void *mi_rend_get_enabled, *mi_rend_isvis, *mi_rend_get_froff, *mi_rend_set_froff, *mi_cam_get_occ;
static void *mi_get_go, *mi_go_active, *mi_go_layer, *mi_rend_allow;

static d_get_main d_cam_main;  static void *mi_cam_main;
static d_obj_get d_tr;         static void *mi_tr;
static d_obj_get d_parent;     static void *mi_parent;
static d_get_position d_pos;   static void *mi_pos;
static d_w2s d_world2screen;   static void *mi_w2s;
static d_screen d_sw, d_sh;    static void *mi_sw, *mi_sh;
static d_get_position d_fwd;   static void *mi_fwd;
static void *k_aim;

static bool g_ready = false;
static bool g_apiOk = false;

static void *direct(void *methodInfo) { return methodInfo ? *(void **)methodInfo : nullptr; }

// ---- bunny hop ---------------------------------------------------------------------------
// PlayerController holds its MovementController in an auto-property backing field (typed field, so we find
// it by TYPE name, which survives obfuscated renames better than the getter name nzr()).
// MovementController.ouk(bool): this+0x88 -> movement state; writes state+0x6F = flag, clears accumulator +0x70 on off.
static const char *kMoveType = "Chillow.StandChillow.Player.Movement.MovementController";
static void *k_move;
static void *mi_move_bhop;          // MovementController.ouk(bool)
static void *mi_pc_move;            // PlayerController.nzr() -> MovementController (fallback if the field scan fails)
static int   g_moveOff = -1;        // PlayerController field offset of the MovementController
static void *g_bhopLastMove = nullptr;
static int   g_bhopLastState = -1;  // -1 = never touched, 0/1 = last value we wrote
static int   g_bhopCount = 0;
static bool  g_bhopForce = false;
static void *k_pcls;                // PlayerController class (params may hang off the player, not only the movement controller)

static void resolveBhop(void *game, void *kpc) {
    k_pcls = kpc;
    k_move = il2_class_from_name(game, "Chillow.StandChillow.Player.Movement", "MovementController");
    if (k_move) mi_move_bhop = findMethod(k_move, "ouk", 1, "System.Boolean");
    if (kpc) {
        mi_pc_move = il2_get_method(kpc, "nzr", 0);
        void *it = nullptr, *f;
        while ((f = il2_class_fields(kpc, &it))) {
            if (il2_field_flags && (il2_field_flags(f) & 0x10)) continue;      // static
            const char *tn = il2_type_name(il2_field_type(f));
            if (tn && strcmp(tn, kMoveType) == 0) { g_moveOff = il2_field_offset(f); break; }
        }
    }
    NSLog(@"[SCESP] bhop: MovementController=%p ouk=%p nzr=%p fieldOff=0x%x", k_move, mi_move_bhop, mi_pc_move, g_moveOff);
}
static void *localMovement(void *me) {
    if (!me) return nullptr;
    if (g_moveOff > 0) return *(void **)((char *)me + g_moveOff);
    return mi_pc_move ? inv(mi_pc_move, me, nullptr) : nullptr;
}
// ---- bunny hop parameters ----------------------------------------------------------------
// The game's bhop physics branch reads three floats: speed step, max speed, reset time. They are found at runtime by FIELD NAME on the
// MovementController and PlayerController object graphs (2 levels deep, inline structs included), so no offsets are hardcoded.
// A float counts when its name contains "bhop", or when its owner class name contains "cheat"/"bhop"; then "step" / "max" / "reset" picks the slot.
// Sliders are multipliers of the value the game had when the field was first seen, so the units never matter.
// If nothing is found the panel says so and every candidate float is printed to the log ("[SCESP] bhop field ...").
struct BhopSlot { float *p; float base; bool have; int prio; };
static BhopSlot g_bhSlot[3];                       // 0 speed step, 1 max speed, 2 reset time
static NSString *g_bhopMsg = @"bhop: -";
static bool g_bhopWrote = false, g_bhopParamsDirty = true;
static int  g_bhopLog = 0, g_bhopObscured = 0;

static std::string lowerOf(const char *s) { std::string o; for (; s && *s; s++) o += (char)tolower((unsigned char)*s); return o; }
static bool hasSub(const std::string &h, const char *n) { return h.find(n) != std::string::npos; }
static bool plausibleObj(void *p) { uintptr_t u = (uintptr_t)p; return u > 0x100000000ULL && (u & 7) == 0; }

static void bhopWalk(void *klass, char *obj, int adj, int depth, std::vector<void *> &seen) {
    typedef const char *(*f_nm)(void *);
    static f_nm cName = (f_nm)dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    if (!klass || !obj || !il2_field_name) return;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        std::string cn = lowerOf(cName ? cName(k) : "");
        bool ownerOk = hasSub(cn, "cheat") || hasSub(cn, "bhop");
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;                       // static
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            const char *fnp = il2_field_name(f);
            if (!tn || !fnp) continue;
            int off = adj + il2_field_offset(f);
            if (!strcmp(tn, "System.Single")) {
                std::string fn = lowerOf(fnp);
                bool named = hasSub(fn, "bhop");
                if (!named && !ownerOk) continue;
                float *fp = (float *)(obj + off);
                if (g_bhopLog < 40) { g_bhopLog++; NSLog(@"[SCESP] bhop field %s.%s = %f (off 0x%x)", cName ? cName(k) : "?", fnp, *fp, off); }
                int slot = hasSub(fn, "step") ? 0 : hasSub(fn, "max") ? 1 : hasSub(fn, "reset") ? 2 : -1;
                if (slot < 0) continue;
                float v = *fp;
                if (v != v || fabsf(v) > 1e6f) continue;                   // NaN / junk
                int prio = named ? 2 : 1;
                if (g_bhSlot[slot].p && g_bhSlot[slot].prio >= prio) continue;
                g_bhSlot[slot].p = fp; g_bhSlot[slot].prio = prio;
                if (!g_bhSlot[slot].have) { g_bhSlot[slot].base = v; g_bhSlot[slot].have = true; }
            } else if (strstr(tn, "ObscuredFloat")) {
                std::string fn = lowerOf(fnp);
                if (hasSub(fn, "bhop") || ownerOk) g_bhopObscured++;       // ACTk-wrapped: not a plain float, left alone
            } else if (il2_class_from_type && il2_class_is_vt && !strncmp(tn, "Chillow.StandChillow.", 21)) {
                void *nk = il2_class_from_type(ft);
                if (!nk) continue;
                if (il2_class_is_vt(nk)) { if (depth < 3) bhopWalk(nk, obj, off - 16, depth + 1, seen); }
                else if (depth < 2) {
                    void *ptr = *(void **)(obj + off);
                    if (!plausibleObj(ptr) || std::find(seen.begin(), seen.end(), ptr) != seen.end()) continue;
                    seen.push_back(ptr);
                    bhopWalk(nk, (char *)ptr, 0, depth + 1, seen);
                }
            }
        }
    }
}
static void bhopDiscover(void *mv, void *me) {
    for (auto &sl : g_bhSlot) { sl.p = nullptr; sl.prio = 0; }
    std::vector<void *> seen;
    if (k_move && mv) { seen.push_back(mv); bhopWalk(k_move, (char *)mv, 0, 0, seen); }
    if (k_pcls && me) { seen.push_back(me); bhopWalk(k_pcls, (char *)me, 0, 0, seen); }
    static const char *nm[3] = { "step", "max", "reset" };
    NSMutableString *m = [NSMutableString stringWithString:@"bhop (game values):"];
    int n = 0;
    for (int i = 0; i < 3; i++) {
        if (g_bhSlot[i].p && g_bhSlot[i].have) { n++; [m appendFormat:@" %s %.3g", nm[i], g_bhSlot[i].base]; }
        else [m appendFormat:@" %s -", nm[i]];
    }
    if (!n) [m appendString:g_bhopObscured ? @"\n(fields are obscured, not writable)" : @"\nnot found, see log"];
    g_bhopMsg = m;
}
static void bhopWriteParams(bool active) {
    const float mult[3] = { g_set.bhopStep, g_set.bhopMax, g_set.bhopReset };
    for (int i = 0; i < 3; i++) {
        BhopSlot &sl = g_bhSlot[i];
        if (!sl.p || !sl.have) continue;
        float v = active ? sl.base * mult[i] : sl.base;                    // inactive = put the game's own value back
        if (*sl.p != v) *sl.p = v;
    }
    g_bhopWrote = active;
}

// called every tick with the local PlayerController (or null). Writes the flag only on change, on a new movement
// controller (respawn / new round) and as a slow re-assert, because the game's own param-apply can overwrite it.
// The parameter floats are re-located about once a second (and on every new controller) and re-asserted every tick while Custom values is on.
static void applyBhop(void *me, bool want) {
    if (!mi_move_bhop) return;
    if (g_bhopLastState < 0 && !want) return;           // never enabled: leave the game alone
    void *mv = localMovement(me);
    if (!mv) return;
    bool newMv = mv != g_bhopLastMove;
    bool due = g_bhopForce || newMv || g_bhopLastState != (want ? 1 : 0) || (++g_bhopCount % 90) == 0;
    if (due) {
        bool v = want;
        void *args[1] = { &v };
        inv(mi_move_bhop, mv, args);
        g_bhopLastMove = mv; g_bhopLastState = want ? 1 : 0; g_bhopForce = false;
    }
    static int pc = 0;
    if (newMv || g_bhopParamsDirty || (++pc % 30) == 0) { bhopDiscover(mv, me); g_bhopParamsDirty = false; }
    bool custom = want && g_set.bhopCustom;
    if (custom || g_bhopWrote) bhopWriteParams(custom);
}

static bool resolveAll() {
    void *core = findImage("UnityEngine.CoreModule.dll");
    void *game = findImage(kGameImage);
    if (!core || !game) return false;

    void *cObject = il2_class_from_name(core, "UnityEngine", "Object");
    void *cCamera = il2_class_from_name(core, "UnityEngine", "Camera");
    void *cComp   = il2_class_from_name(core, "UnityEngine", "Component");
    void *cTrans  = il2_class_from_name(core, "UnityEngine", "Transform");
    void *cScreen = il2_class_from_name(core, "UnityEngine", "Screen");
    void *cRend   = il2_class_from_name(core, "UnityEngine", "Renderer");
    k_smr         = il2_class_from_name(core, "UnityEngine", "SkinnedMeshRenderer");
    k_material    = il2_class_from_name(core, "UnityEngine", "Material");
    k_shader      = il2_class_from_name(core, "UnityEngine", "Shader");
    if (!cObject || !cCamera || !cComp || !cTrans || !cScreen) return false;

    mi_get_name = il2_get_method(cObject, "get_name", 0);
    // FindObjectsOfType(Type) is stripped in this build; (Type, bool) is present.
    mi_find     = il2_get_method(cObject, "FindObjectsOfType", 2);
    mi_cam_main = il2_get_method(cCamera, "get_main", 0);
    mi_w2s      = il2_get_method(cCamera, "WorldToScreenPoint", 1);
    mi_tr       = il2_get_method(cComp, "get_transform", 0);
    mi_pos      = il2_get_method(cTrans, "get_position", 0);
    mi_parent   = il2_get_method(cTrans, "get_parent", 0);
    mi_fwd      = il2_get_method(cTrans, "get_forward", 0);
    mi_sw       = il2_get_method(cScreen, "get_width", 0);
    mi_sh       = il2_get_method(cScreen, "get_height", 0);
    d_cam_main = (d_get_main)direct(mi_cam_main);
    d_world2screen = (d_w2s)direct(mi_w2s);
    d_tr  = (d_obj_get)direct(mi_tr);
    d_parent = (d_obj_get)direct(mi_parent);
    d_fwd = (d_get_position)direct(mi_fwd);
    d_pos = (d_get_position)direct(mi_pos);
    d_sw  = (d_screen)direct(mi_sw);
    d_sh  = (d_screen)direct(mi_sh);

    // skeleton / chams helpers (all optional: missing ones just disable that feature)
    if (k_smr)  mi_get_bones = il2_get_method(k_smr, "get_bones", 0);
    {   // occlusion / animation-culling overrides (optional)
        void *cBeh = il2_class_from_name(core, "UnityEngine", "Behaviour");
        if (cBeh) mi_beh_enabled = il2_get_method(cBeh, "set_enabled", 1);
        if (cRend) mi_rend_enabled = il2_get_method(cRend, "set_enabled", 1);
        if (cRend) {
            mi_rend_get_enabled = il2_get_method(cRend, "get_enabled", 0);
            mi_rend_isvis       = il2_get_method(cRend, "get_isVisible", 0);
            mi_rend_get_froff   = il2_get_method(cRend, "get_forceRenderingOff", 0);
            mi_rend_set_froff   = il2_get_method(cRend, "set_forceRenderingOff", 1);
            mi_rend_allow       = il2_get_method(cRend, "set_allowOcclusionWhenDynamic", 1);
        }
        mi_cam_get_occ = il2_get_method(cCamera, "get_useOcclusionCulling", 0);
        mi_get_go = il2_get_method(cComp, "get_gameObject", 0);
        { void *cGO = il2_class_from_name(core, "UnityEngine", "GameObject");
          if (cGO) { mi_go_active = il2_get_method(cGO, "get_activeInHierarchy", 0); mi_go_layer = il2_get_method(cGO, "get_layer", 0); } }
        if (k_smr) mi_smr_offscreen = il2_get_method(k_smr, "set_updateWhenOffscreen", 1);
        mi_cam_occ = il2_get_method(cCamera, "set_useOcclusionCulling", 1);
        void *animImg = findImage("UnityEngine.AnimationModule.dll");
        if (animImg) {
            k_animator = il2_class_from_name(animImg, "UnityEngine", "Animator");
            if (k_animator) mi_anim_cull = il2_get_method(k_animator, "set_cullingMode", 1);
        }
        k_occsys = il2_class_from_name(game, "Chillow.StandChillow.Occlusion.Dynamic", "OcclusionSystem");
    }
    if (cRend) {
        mi_get_smats = il2_get_method(cRend, "get_sharedMaterials", 0);
        mi_set_smats = il2_get_method(cRend, "set_sharedMaterials", 1);
    }
    if (k_shader) {
        mi_find_shader = findMethod(k_shader, "Find", 1, "System.String");
        mi_setglobal   = findMethod(k_shader, "SetGlobalFloat", 2, "System.String");
    }
    if (k_material) {
        mi_mat_ctor  = findMethod(k_material, ".ctor", 1, "UnityEngine.Shader");
        mi_set_color = il2_get_method(k_material, "set_color", 1);
        mi_set_queue = il2_get_method(k_material, "set_renderQueue", 1);
        mi_setint    = findMethod(k_material, "SetInt", 2, "System.String");
        mi_hasprop   = findMethod(k_material, "HasProperty", 1, "System.String");
    }
    {   // CommandBuffer chams: everything optional, a miss just keeps the old material-swap path
        k_cmdbuf = il2_class_from_name(core, "UnityEngine.Rendering", "CommandBuffer");
        if (k_cmdbuf) {
            mi_cb_ctor  = il2_get_method(k_cmdbuf, ".ctor", 0);
            mi_cb_clear = il2_get_method(k_cmdbuf, "Clear", 0);
            mi_cb_draw2 = findMethod(k_cmdbuf, "DrawRenderer", 2, "UnityEngine.Renderer");
            mi_cb_draw3 = findMethod(k_cmdbuf, "DrawRenderer", 3, "UnityEngine.Renderer");
        }
        mi_cam_addcb = findMethod(cCamera, "AddCommandBuffer", 2, "UnityEngine.Rendering.CameraEvent");
        mi_cam_rmcb  = findMethod(cCamera, "RemoveCommandBuffer", 2, "UnityEngine.Rendering.CameraEvent");
        NSLog(@"[SCESP] cmdbuf: class=%p ctor=%p clear=%p draw2=%p draw3=%p add=%p rm=%p", k_cmdbuf, mi_cb_ctor, mi_cb_clear, mi_cb_draw2, mi_cb_draw3, mi_cam_addcb, mi_cam_rmcb);
    }

    for (int i = 0; i < kN; i++) k_targets[i] = il2_class_from_name(game, kTargets[i].ns, kTargets[i].name);
    { void *kpc = il2_class_from_name(game, "Chillow.StandChillow.Player", "PlayerController");
      if (kpc) mi_hp = il2_get_method(kpc, "ode", 0);
      if (kpc) { mi_armor = il2_get_method(kpc, "odf", 0); mi_helm = il2_get_method(kpc, "odg", 0); }
      NSLog(@"[SCESP] PlayerController.ode() = %p odf() = %p odg() = %p", mi_hp, mi_armor, mi_helm);
      resolveBhop(game, kpc); }
    k_aim = il2_class_from_name(game, "Chillow.StandChillow.Player.Aim", "AimController");
    for (int r = 1; r < kHpRoots; r++) k_hpRoot[r] = il2_class_from_name(game, kHpRootDefs[r].ns, kHpRootDefs[r].name);
    if (il2_resolve_icall) {
        auto ic = [](const char *a, const char *b) -> void * { void *p = il2_resolve_icall(a); return p ? p : il2_resolve_icall(b); };
        ic_cam_set_occ   = (ic_set_bool)ic("UnityEngine.Camera::set_useOcclusionCulling(System.Boolean)", "UnityEngine.Camera::set_useOcclusionCulling");
        ic_cam_get_occ   = (ic_get_bool)ic("UnityEngine.Camera::get_useOcclusionCulling()", "UnityEngine.Camera::get_useOcclusionCulling");
        ic_rend_vis      = (ic_get_bool)ic("UnityEngine.Renderer::get_isVisible()", "UnityEngine.Renderer::get_isVisible");
        ic_rend_set_allow = (ic_set_bool)ic("UnityEngine.Renderer::set_allowOcclusionWhenDynamic(System.Boolean)", "UnityEngine.Renderer::set_allowOcclusionWhenDynamic");
        NSLog(@"[SCESP] icalls: setOcc=%p getOcc=%p isVisible=%p allowOcc=%p", ic_cam_set_occ, ic_cam_get_occ, ic_rend_vis, ic_rend_set_allow);
    }
    NSLog(@"[SCESP] resolve: find=%p cam=%p w2s=%p tr=%p pos=%p parent=%p bones=%p",
          mi_find, d_cam_main, d_world2screen, d_tr, d_pos, d_parent, mi_get_bones);
    bool any = false; for (int i = 0; i < kN; i++) if (k_targets[i]) any = true;
    return mi_find && d_cam_main && d_world2screen && d_tr && d_pos && d_sw && d_sh && any;
}

static void findTeamFields(void *klass) {
    g_teamOffsets.clear();
    g_teamField = -1;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            const char *tn = il2_type_name(il2_field_type(f));
            if (tn && strcmp(tn, kTeamType) == 0) g_teamOffsets.push_back(il2_field_offset(f));
        }
    }
}

static inline bool alive(void *obj) { return obj && *(void **)((char *)obj + 16) != nullptr; }
static inline int readTeam(void *obj, int field) {
    if (field < 0 || field >= (int)g_teamOffsets.size()) return 0;
    return *(int *)((char *)obj + g_teamOffsets[field]);
}

// ---- aim lock (offline) ----------------------------------------------------------------
// The look angles live in obfuscated float fields, so they are LEARNED at runtime: while the user
// turns the view, every float field of the local PlayerController / AimController (one nesting level
// deep) is correlated with the camera's yaw / pitch. The best match is then nudged toward the target.
// The correction is computed from the camera's real forward vector every tick, so recoil kicks are
// compensated one tick later.
static std::vector<uint32_t> g_aimH;
struct Cand { uint8_t src, deref; int off, off2; const char *n1, *n2; };
struct Stat { float last = 0; bool have = false; double sv2 = 0, sy2 = 0, sp2 = 0, svy = 0, svp = 0, wdv = 0; int n = 0; };
static std::vector<Cand> g_cands;
static std::vector<Stat> g_stats;
static bool g_learn = false, g_lhave = false;
static float g_ly = 0, g_lp = 0;
static double g_learnT0 = 0, g_msgUntil = 0;
static NSString *g_learnMsg = @"aim: not learned";
static Cand g_yawC = {0, 0, 0, 0, nullptr, nullptr}, g_pitC = {0, 0, 0, 0, nullptr, nullptr};
static float g_yawK = 0, g_pitK = 0;
static bool g_haveYaw = false, g_havePit = false;

static inline float wrap180(float a) { while (a > 180.f) a -= 360.f; while (a < -180.f) a += 360.f; return a; }

static void pushCand(uint8_t src, int mode, int outer, int off, const char *fn, const char *on) {
    if (g_cands.size() > 8000) return;
    Cand c; c.src = src; c.n1 = on; c.n2 = fn;
    if (mode == 0)      { c.deref = 0; c.off = off; c.off2 = 0; }
    else if (mode == 1) { c.deref = 0; c.off = outer + off - 16; c.off2 = 0; }   // inline struct
    else                { c.deref = 1; c.off = outer; c.off2 = off; }            // through a reference
    g_cands.push_back(c);
}
static void scanClass(void *klass, uint8_t src, int mode, int outer, int depth, const char *oname = nullptr) {
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            if (!tn) continue;
            int off = il2_field_offset(f);
            const char *fn = il2_field_name ? il2_field_name(f) : "?";
            if (!strcmp(tn, "System.Single")) pushCand(src, mode, outer, off, fn, oname);
            else if (!strcmp(tn, "UnityEngine.Vector2")) { pushCand(src, mode, outer, off, fn, oname); pushCand(src, mode, outer, off + 4, fn, oname); }
            else if (!strcmp(tn, "UnityEngine.Vector3")) { for (int q = 0; q < 3; q++) pushCand(src, mode, outer, off + 4 * q, fn, oname); }   // euler angles
            else if (depth == 0 && mode == 0 && il2_class_from_type && il2_class_is_vt && !strncmp(tn, "Chillow.StandChillow.", 21)) {
                void *nk = il2_class_from_type(ft);
                if (nk) scanClass(nk, src, il2_class_is_vt(nk) ? 1 : 2, off, 1, fn);
            }
        }
    }
}
static float *candAddr(const Cand &c, void *me, void *aim) {
    char *o = (char *)(c.src == 0 ? me : aim);
    if (!o) return nullptr;
    if (c.deref) { char *p = *(char **)(o + c.off); return p ? (float *)(p + c.off2) : nullptr; }
    return (float *)(o + c.off);
}
static void *nearestAim(V3 cp) {
    void *best = nullptr; float bd = 1e9f;
    for (uint32_t h : g_aimH) {
        void *o = il2_gc_get(h);
        if (!alive(o)) continue;
        void *tr = d_tr(o, mi_tr);
        if (!tr) continue;
        V3 q = d_pos(tr, mi_pos);
        float dx = q.x - cp.x, dy = q.y - cp.y, dz = q.z - cp.z, d = dx * dx + dy * dy + dz * dz;
        if (d < bd) { bd = d; best = o; }
    }
    return best;
}
static void saveAim() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (g_haveYaw) [d setObject:@[@(g_yawC.src), @(g_yawC.deref), @(g_yawC.off), @(g_yawC.off2), @(g_yawK)] forKey:@"scesp_yawc"];
    if (g_havePit) [d setObject:@[@(g_pitC.src), @(g_pitC.deref), @(g_pitC.off), @(g_pitC.off2), @(g_pitK)] forKey:@"scesp_pitc"];
}
static void loadAim() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *y = [d arrayForKey:@"scesp_yawc"], *p = [d arrayForKey:@"scesp_pitc"];
    if (y.count == 5) { g_yawC.src = [y[0] intValue]; g_yawC.deref = [y[1] intValue]; g_yawC.off = [y[2] intValue]; g_yawC.off2 = [y[3] intValue]; g_yawK = [y[4] floatValue]; g_haveYaw = true; }
    if (p.count == 5) { g_pitC.src = [p[0] intValue]; g_pitC.deref = [p[1] intValue]; g_pitC.off = [p[2] intValue]; g_pitC.off2 = [p[3] intValue]; g_pitK = [p[4] floatValue]; g_havePit = true; }
    if (g_haveYaw && g_havePit) g_learnMsg = @"aim: learned fields loaded";
}
// Correlation is taken over ~6-tick windows (about 0.1 s): the game applies its look input a frame
// before / after the camera transform moves, so per-tick deltas of the right field do not line up.
// Probe: a field that correlates 1.00 with the camera can still be a mirror the game rewrites every
// frame. Each strong candidate is nudged by a known amount; only the one that really turns the view wins.
struct PC { Cand c; float k; double r; };
static std::vector<PC> g_probeY, g_probeP;
static int g_probeAxis = -1;            // -1 idle, 0 testing yaw list, 1 testing pitch list
static size_t g_probeIdx = 0;
static int g_probePhase = 0;
static double g_probeT0 = 0, g_probeBegin = 0;
static float g_probeStart = 0, g_probeOrig = 0, g_probeLastY = 0, g_probeLastP = 0;
static bool g_probeHaveLast = false, g_probeOkY = false, g_probeOkP = false;
static NSMutableString *g_report = nil;
static float g_wdy = 0, g_wdp = 0, g_totY = 0, g_totP = 0;
static int g_wn = 0;
static NSString *candName(const Cand &c) {
    return [NSString stringWithFormat:@"%s%s%s%s", c.src ? "aim." : "me.", c.n1 ? c.n1 : "", c.n1 ? "." : "", c.n2 ? c.n2 : "?"];
}
static void learnStep(void *me, void *aim, float yaw, float pit) {
    if (!g_lhave) {
        g_ly = yaw; g_lp = pit; g_lhave = true; g_wdy = g_wdp = 0; g_wn = 0; g_totY = g_totP = 0;
        for (size_t i = 0; i < g_cands.size(); i++) { float *a = candAddr(g_cands[i], me, aim); g_stats[i].have = a != nullptr; g_stats[i].wdv = 0; if (a) g_stats[i].last = *a; }
        return;
    }
    float dy = wrap180(yaw - g_ly), dp = pit - g_lp;
    g_ly = yaw; g_lp = pit;
    g_wdy += dy; g_wdp += dp; g_totY += fabsf(dy); g_totP += fabsf(dp);
    for (size_t i = 0; i < g_cands.size(); i++) {
        Stat &s = g_stats[i];
        float *a = candAddr(g_cands[i], me, aim);
        if (!a) { s.have = false; continue; }
        float v = *a;
        if (!s.have) { s.last = v; s.have = true; continue; }
        float dv = v - s.last; s.last = v;
        if (dv > 180.f) dv -= 360.f; else if (dv < -180.f) dv += 360.f;
        if (dv == dv && fabsf(dv) < 200.f) s.wdv += dv;
    }
    if (++g_wn < 6) return;
    bool moved = fabsf(g_wdy) > 0.3f || fabsf(g_wdp) > 0.3f;
    if (moved && fabsf(g_wdy) < 90.f) {
        for (size_t i = 0; i < g_cands.size(); i++) {
            Stat &s = g_stats[i];
            double dv = s.wdv;
            s.sv2 += dv * dv; s.sy2 += (double)g_wdy * g_wdy; s.sp2 += (double)g_wdp * g_wdp;
            s.svy += dv * g_wdy; s.svp += dv * g_wdp; s.n++;
        }
    }
    for (auto &s : g_stats) s.wdv = 0;
    g_wdy = g_wdp = 0; g_wn = 0;
}
static void learnFinish() {
    g_learn = false; g_lhave = false;
    const double kAccept = 0.90;
    struct R { double ry, rp, sy, sp; };
    std::vector<R> rs(g_cands.size(), R{0, 0, 0, 0});
    int by = -1, bp = -1; double cy = 0, cp = 0, ky = 0, kp = 0;
    size_t used = 0;
    for (size_t i = 0; i < g_cands.size(); i++) {
        Stat &s = g_stats[i];
        if (s.n < 8 || s.sv2 < 1e-12) continue;
        used++;
        R &r = rs[i];
        r.ry = s.svy / sqrt(s.sv2 * s.sy2 + 1e-18); r.rp = s.svp / sqrt(s.sv2 * s.sp2 + 1e-18);
        r.sy = s.svy / (s.sy2 + 1e-12);             r.sp = s.svp / (s.sp2 + 1e-12);
        if (s.sy2 > 20 && fabs(r.sy) > 0.005 && fabs(r.sy) < 50 && fabs(r.ry) > cy) { cy = fabs(r.ry); by = (int)i; ky = r.sy; }
        if (s.sp2 > 20 && fabs(r.sp) > 0.005 && fabs(r.sp) < 50 && fabs(r.rp) > cp) { cp = fabs(r.rp); bp = (int)i; kp = r.sp; }
    }
    bool okY = by >= 0 && cy >= kAccept, okP = bp >= 0 && cp >= kAccept;
    if (okY && okP && by == bp) { if (cy >= cp) okP = false; else okY = false; }
    if (okY) { g_yawC = g_cands[by]; g_yawK = (float)ky; g_haveYaw = true; }
    if (okP) { g_pitC = g_cands[bp]; g_pitK = (float)kp; g_havePit = true; }
    if (okY || okP) saveAim();
    g_probeY.clear(); g_probeP.clear();
    for (size_t i = 0; i < g_cands.size(); i++) {
        Stat &st = g_stats[i];
        if (st.n < 8 || st.sv2 < 1e-12) continue;
        const R &r = rs[i];
        if (st.sy2 > 20 && fabs(r.sy) > 0.005 && fabs(r.sy) < 50 && fabs(r.ry) >= 0.95) g_probeY.push_back({ g_cands[i], (float)r.sy, fabs(r.ry) });
        if (st.sp2 > 20 && fabs(r.sp) > 0.005 && fabs(r.sp) < 50 && fabs(r.rp) >= 0.95) g_probeP.push_back({ g_cands[i], (float)r.sp, fabs(r.rp) });
    }
    auto byR = [](const PC &a, const PC &b) { return a.r > b.r; };
    std::sort(g_probeY.begin(), g_probeY.end(), byR); std::sort(g_probeP.begin(), g_probeP.end(), byR);
    if (g_probeY.size() > 24) g_probeY.resize(24);
    if (g_probeP.size() > 24) g_probeP.resize(24);
    g_probeAxis = !g_probeY.empty() ? 0 : (!g_probeP.empty() ? 1 : -1);
    g_probeIdx = 0; g_probePhase = 0; g_probeHaveLast = false; g_probeOkY = g_probeOkP = false;
    g_probeBegin = CACurrentMediaTime();

    // full report -> clipboard + log, so the numbers can be inspected without a console
    NSMutableString *rep = [NSMutableString stringWithFormat:@"cands=%zu used=%zu rot yaw=%.0f pit=%.0f deg\n", g_cands.size(), used, g_totY, g_totP];
    for (int axis = 0; axis < 2; axis++) {
        std::vector<std::pair<double, size_t>> top;
        for (size_t i = 0; i < g_cands.size(); i++) if (g_stats[i].n >= 8 && g_stats[i].sv2 > 1e-12) top.push_back({ fabs(axis ? rs[i].rp : rs[i].ry), i });
        std::sort(top.begin(), top.end(), [](const std::pair<double, size_t> &a, const std::pair<double, size_t> &b) { return a.first > b.first; });
        [rep appendFormat:@"-- top %s --\n", axis ? "pitch" : "yaw"];
        for (size_t t = 0; t < top.size() && t < 12; t++) {
            const Cand &c = g_cands[top[t].second]; const R &r = rs[top[t].second];
            [rep appendFormat:@"%.3f k=%.4f %@ off=%d/%d\n", top[t].first, axis ? r.sp : r.sy, candName(c), c.off, c.off2];
        }
    }
    g_report = rep;
    UIPasteboard.generalPasteboard.string = rep;
    NSLog(@"[SCESP] learn report\n%@", rep);

    g_learnMsg = [NSString stringWithFormat:@"learn y %s%.2f p %s%.2f rot %.0f/%.0f", okY ? "OK" : "NO", cy, okP ? "OK" : "NO", cp, g_totY, g_totP];
    g_msgUntil = CACurrentMediaTime() + 20;
}
static void probeStep(void *me, void *aim, float cy, float cp, double now) {
    bool still = true;
    if (g_probeHaveLast) still = fabsf(wrap180(cy - g_probeLastY)) < 0.15f && fabsf(cp - g_probeLastP) < 0.15f;
    g_probeLastY = cy; g_probeLastP = cp; g_probeHaveLast = true;
    std::vector<PC> &list = g_probeAxis == 0 ? g_probeY : g_probeP;
    bool timeout = now - g_probeBegin > 45.0;
    if (timeout || g_probeIdx >= list.size()) {
        if (!timeout && g_probeAxis == 0 && !g_probeP.empty()) { g_probeAxis = 1; g_probeIdx = 0; g_probePhase = 0; return; }
        g_probeAxis = -1; g_probeHaveLast = false;
        saveAim();
        g_learnMsg = [NSString stringWithFormat:@"aim probe: yaw %s pit %s%s", g_probeOkY ? "OK" : "NO", g_probeOkP ? "OK" : "NO", timeout ? " (timeout)" : ""];
        g_msgUntil = now + 20;
        if (g_report) { [g_report appendFormat:@"== probe: yaw %d pit %d\n", g_probeOkY, g_probeOkP]; UIPasteboard.generalPasteboard.string = g_report; }
        return;
    }
    PC &pc = list[g_probeIdx];
    g_learnMsg = [NSString stringWithFormat:@"probe %s %zu/%zu - hold still", g_probeAxis ? "pitch" : "yaw", g_probeIdx + 1, list.size()];
    g_msgUntil = now + 2;
    float *a = candAddr(pc.c, me, aim);
    if (!a) { g_probeIdx++; g_probePhase = 0; return; }
    if (g_probePhase == 0) {
        if (!still) return;
        g_probeOrig = *a; g_probeStart = g_probeAxis == 0 ? cy : cp;
        *a += pc.k * 4.0f;                      // ask the game to turn the view by +4 degrees through this field
        g_probePhase = 1; g_probeT0 = now;
        return;
    }
    float d = g_probeAxis == 0 ? wrap180(cy - g_probeStart) : cp - g_probeStart;
    bool inWin = d > 2.0f && d < 6.5f;
    if (g_probePhase == 1) {
        if (now - g_probeT0 < 0.25) return;
        if (inWin) { g_probePhase = 2; return; }        // turned: now check that it STAYS turned
    } else {
        if (now - g_probeT0 < 0.9) return;
        if (inWin) {
            float kc = pc.k * 4.0f / d;                  // field units per degree actually achieved
            if (g_probeAxis == 0) { g_yawC = pc.c; g_yawK = kc; g_haveYaw = true; g_probeOkY = true; }
            else                  { g_pitC = pc.c; g_pitK = kc; g_havePit = true; g_probeOkP = true; }
            if (g_report) [g_report appendFormat:@"== DRIVER %s: %@ off=%d/%d k=%.4f (regress %.4f) moved=%.2f\n", g_probeAxis ? "pitch" : "yaw", candName(pc.c), pc.c.off, pc.c.off2, kc, pc.k, d];
            g_probeIdx = list.size();                    // axis solved
            g_probePhase = 0;
            return;
        }
    }
    if (g_report) [g_report appendFormat:@"   rejected: %@ (moved %.2f, phase %d)\n", candName(pc.c), d, g_probePhase];
    *a = g_probeOrig;                                    // mirror, no effect, or a decaying offset
    g_probeIdx++;
    g_probePhase = 0;
}
static double g_aimLastW = 0;
struct AimTg {
    V3 pos; void *id;
    V3 partPos[kAimPartCount];
    uint8_t partCount[kAimPartCount];
};
static void *g_lockId = nullptr;         // target we are currently locked on (sticky, so we do not flick between bots)

// ---- silent aim ------------------------------------------------------------------------
// The tick fills the snapshot below once per frame (camera, view forward, enemy aim points).
// The fire hook calls silentAimApply() right before the original shot call.
static std::vector<silent_aim::Target> g_silentTargets;
static silent_aim::Vec3 g_silentCam{}, g_silentFwd{};
static bool g_silentOffline = false;     // set by the tick: other characters exist and all are bots
static bool g_silentFresh = false;
static void *g_silentLastId = nullptr;

static inline silent_aim::Vec3 toSA(V3 v) { return { v.x, v.y, v.z }; }

// direction: the shot direction the game is about to use (in/out).  shotOrigin: real muzzle / trace start.
// aimKeyDown: pass true if the shot is always allowed to be redirected (the toggle itself is the gate).
static bool silentAimApply(V3 shotOriginIn, V3 &directionInOut, bool aimKeyDown) {
    if (!g_set.silent || !g_silentOffline || !g_silentFresh || g_silentTargets.empty()) return false;

    silent_aim::ShotContext ctx{
        g_silentCam,                 // cameraOrigin
        toSA(shotOriginIn),          // shotOrigin
        g_silentFwd,                 // viewForward
        aimKeyDown                   // active
    };
    silent_aim::Settings settings;
    settings.enabled = true;
    settings.requireVisible = false; // the snapshot has no line-of-sight data
    settings.maxFovDegrees = g_set.silentFov;
    settings.maxDistance = 0.0f;

    silent_aim::ShotSolution solution;
    if (silent_aim::BuildSilentShot(ctx, g_silentTargets, settings, solution)) {
        directionInOut = { solution.direction.x, solution.direction.y, solution.direction.z };
        g_silentLastId = (void *)solution.entity;
        return true;
    }
    return false;
}
// Runs on EVERY tick with the real elapsed time: first-order approach to the target, so the motion does not depend
// on the tick rate (the run loop can wake several times per frame). Small cap on the angular speed = no snapping.
// AimController -> AimingData (+0x80): curEulerAngles.y (+0x28) is the yaw, curAimAngle.x (+0x18) the pitch, in degrees
static void useDumpFields() {
    g_yawC.src = 1; g_yawC.deref = 1; g_yawC.off = 0x80; g_yawC.off2 = 0x28; g_yawK = 1.f; g_haveYaw = true;
    g_pitC.src = 1; g_pitC.deref = 1; g_pitC.off = 0x80; g_pitC.off2 = 0x18; g_pitK = 1.f; g_havePit = true;
    saveAim();
    g_learnMsg = @"aim: AimingData fields from the dump"; g_msgUntil = CACurrentMediaTime() + 8;
}
static void aimStep(void *me, void *aim, float dyaw, float dpit, float dt) {
    float *py = candAddr(g_yawC, me, aim), *pp = candAddr(g_pitC, me, aim);
    float s = 1.f - expf(-dt * g_set.aimSpeed);
    float cap = 320.f * dt;                                   // max degrees per tick (~320 deg/s)
    dyaw = fmaxf(-cap, fminf(cap, dyaw * s));
    dpit = fmaxf(-cap, fminf(cap, dpit * s));
    if (py) *py += g_yawK * dyaw;
    if (pp) *pp += g_pitK * dpit;
}

// ---- scene scan ------------------------------------------------------------------------
struct PlayerInfo {
    std::vector<char> skip;         // per bone: junk bone (by name), never drawn
    std::vector<int8_t> part;        // cached body region for aim-point selection
    uint32_t obj = 0;
    std::vector<uint32_t> smr;      // SkinnedMeshRenderer handles belonging to this player
    std::vector<uint32_t> anim;     // Animator handles belonging to this player
    uint32_t body = 0;              // the SMR with the most bones = third-person body (not FP arms)
    std::vector<uint32_t> bone;     // Transform handles (biggest SMR's bones)
    std::vector<int> parent;        // parent index inside `bone`, or -1
    std::vector<uint32_t> hproot;   // handles of hit / network components of this player (health search), index = root id
};
static std::vector<PlayerInfo> g_pl;

static std::unordered_map<void *, char> g_skipCache;
static int g_dumped = 0;
static bool boneNameSkip(void *tr) {
    auto it = g_skipCache.find(tr);
    if (it != g_skipCache.end()) return it->second;
    bool skip = false;
    if (mi_get_name && il2_str_chars && il2_str_len) {
        void *str = inv(mi_get_name, tr, nullptr);
        if (str) {
            int len = il2_str_len(str);
            const uint16_t *ch = il2_str_chars(str);
            char buf[96]; int n = len < 95 ? len : 95; if (n < 0) n = 0;
            for (int i = 0; i < n; i++) buf[i] = ch[i] < 128 ? (char)tolower(ch[i]) : '?';
            buf[n] = 0;
            for (const char *k : kBoneSkip) if (strstr(buf, k)) { skip = true; break; }
            if (g_dumped < 90) { g_dumped++; NSLog(@"[SCESP] bone '%s'%s", buf, skip ? " (skipped)" : ""); }
        }
    }
    if (g_skipCache.size() > 8192) g_skipCache.clear();
    g_skipCache[tr] = skip;
    return skip;
}

static std::unordered_map<void *, int8_t> g_partCache;
static int8_t boneAimPart(void *tr) {
    auto cached = g_partCache.find(tr);
    if (cached != g_partCache.end()) return cached->second;
    int8_t part = -1;
    if (mi_get_name && il2_str_chars && il2_str_len) {
        void *str = inv(mi_get_name, tr, nullptr);
        if (str) {
            int len = il2_str_len(str);
            const uint16_t *ch = il2_str_chars(str);
            char name[96]; int n = len < 95 ? len : 95; if (n < 0) n = 0;
            for (int i = 0; i < n; i++) name[i] = ch[i] < 128 ? (char)tolower(ch[i]) : '?';
            name[n] = 0;
            if (strstr(name, "head")) part = kAimHead;
            else if (strstr(name, "neck")) part = kAimNeck;
            else if (strstr(name, "foot") || strstr(name, "ankle") || strstr(name, "toe")) part = kAimFoot;
            else if (strstr(name, "pelvis") || strstr(name, "hip")) part = kAimPelvis;
            else if (strstr(name, "arm") || strstr(name, "shoulder") || strstr(name, "elbow") || strstr(name, "wrist") || strstr(name, "hand")) part = kAimArm;
            else if (strstr(name, "leg") || strstr(name, "thigh") || strstr(name, "knee") || strstr(name, "calf")) part = kAimLeg;
            else if (strstr(name, "chest") || strstr(name, "rib") || strstr(name, "upperchest") || strstr(name, "spine2") || strstr(name, "spine_02") || strstr(name, "torso")) part = kAimChest;
            else if (strstr(name, "stomach") || strstr(name, "abdomen") || strstr(name, "spine1") || strstr(name, "spine_01") || strstr(name, "spine")) part = kAimStomach;
        }
    }
    if (g_partCache.size() > 8192) g_partCache.clear();
    g_partCache[tr] = part;
    return part;
}

static char fallbackAimPart(float relativeY, float bodyHeight) {
    float h = fmaxf(1.2f, bodyHeight);
    if (relativeY > h * 0.84f) return kAimHead;
    if (relativeY > h * 0.73f) return kAimNeck;
    if (relativeY > h * 0.54f) return kAimChest;
    if (relativeY > h * 0.37f) return kAimStomach;
    if (relativeY > h * 0.23f) return kAimPelvis;
    if (relativeY > h * 0.07f) return kAimLeg;
    return kAimFoot;
}

static void freeInfo(PlayerInfo &p) {
    if (p.obj) il2_gc_free(p.obj);
    for (uint32_t h : p.smr) il2_gc_free(h);
    for (uint32_t h : p.anim) il2_gc_free(h);
    if (p.body) il2_gc_free(p.body);
    for (uint32_t h : p.bone) il2_gc_free(h);
    for (uint32_t h : p.hproot) if (h) il2_gc_free(h);
}

static size_t findObjs(void *klass, std::vector<void *> &out, size_t cap) {
    void *typeObj = il2_type_object(il2_class_type(klass));
    bool inactive = false;
    void *args[2] = { typeObj, &inactive };
    void *arr = inv(mi_find, nullptr, args);
    if (!arr) return 0;
    uintptr_t len = *(uintptr_t *)((char *)arr + 24);
    void **elems = (void **)((char *)arr + 32);
    if (len > cap) len = cap;
    size_t n = 0;
    for (uintptr_t i = 0; i < len; i++) if (elems[i]) { out.push_back(elems[i]); n++; }
    return n;
}

// ---- custom hands position (viewmodel) + stretched resolution (v5.8) ----------------------------------------------
// Static dump, StandChillow 2.07:  GameSettings { +0x1C FieldOfViewType(enum), +0x20 CustomViewModel, +0x2C HandsPositionType(enum) }
//   CustomViewModel { +0x10 PositionOffset(Vector3), +0x1C RotationOffset(Vector3), +0x28 AdditiveFov(float) }
//   PlayerController.obu(GameSettings) @0x281EC8C is the settings callback of the local player; PlayerFPSCamera.betr(GameSettings) @0x2762F18.
// Offsets above are only fallbacks; everything is looked up by field name first. Nothing here was run on a device.
typedef void *(*fn_object_get_class)(void *);
typedef const char *(*fn_class_get_name)(void *);
typedef size_t (*fn_image_class_count)(void *);
typedef void *(*fn_image_get_class)(void *, size_t);
typedef void (*fn_field_static_get)(void *, void *);
typedef void *(*fn_class_elem)(void *);
static fn_object_get_class il2_obj_class;
static fn_class_get_name il2_class_name;
static fn_image_class_count il2_img_count;
static fn_image_get_class il2_img_class;
static fn_field_static_get il2_static_get;
static fn_class_elem il2_class_elem;

static bool g_vmApiTried = false, g_vmApi = false;
static void *k_gs, *k_cvm, *k_fpscam, *mi_obu, *mi_betr;
static uint32_t g_gsH = 0;                    // gchandle of the live GameSettings (0 = not found yet)
static double g_vmLastFind = 0;
static int g_offCvm = -1, g_offHands = -1, g_offFovT = -1, g_offPos = -1, g_offRot = -1, g_offFov = -1;
static bool g_vmSaved = false, g_vmWasOn = false, g_vmForce = true;
static float g_vmOrig[7];
static int g_vmOrigHands = 0, g_vmOrigFovT = 0;
static void *g_vmLastMe = nullptr;
static int g_vmTick = 0;
static NSString *g_vmMsg = @"viewmodel: off";
static NSString *g_vmEnums = @"";

static void *g_gameImg = nullptr;
static void *gameImage() { if (!g_gameImg) g_gameImg = findImage(kGameImage); return g_gameImg; }

static int fieldOffByName(void *klass, const char *name) {
    if (!il2_field_name || !klass) return -1;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *it = nullptr, *f;
        while ((f = il2_class_fields(k, &it))) {
            if (il2_field_flags && (il2_field_flags(f) & 0x10)) continue;      // static
            const char *n = il2_field_name(f);
            if (n && strcmp(n, name) == 0) return il2_field_offset(f);
        }
    }
    return -1;
}

static void loadVmApi() {
    if (g_vmApiTried) return;
    g_vmApiTried = true;
    il2_obj_class  = (fn_object_get_class)sym("il2cpp_object_get_class");
    il2_class_name = (fn_class_get_name)sym("il2cpp_class_get_name");
    il2_img_count  = (fn_image_class_count)sym("il2cpp_image_get_class_count");        // optional (static-field search)
    il2_img_class  = (fn_image_get_class)sym("il2cpp_image_get_class");                // optional
    il2_static_get = (fn_field_static_get)sym("il2cpp_field_static_get_value");        // optional
    il2_class_elem = (fn_class_elem)sym("il2cpp_class_get_element_class");             // optional (arrays)
    void *game = gameImage();
    if (!game || !il2_obj_class || !il2_class_name || !il2_class_from_type || !il2_class_is_vt) { g_vmMsg = @"viewmodel: il2cpp api missing"; return; }
    k_gs     = il2_class_from_name(game, "Chillow.StandChillow.Settings.Game", "GameSettings");
    k_fpscam = il2_class_from_name(game, "Chillow.StandChillow.Cam", "PlayerFPSCamera");
    if (k_pcls) mi_obu = findMethod(k_pcls, "obu", 1, "Chillow.StandChillow.Settings.Game.GameSettings");
    if (k_fpscam) mi_betr = findMethod(k_fpscam, "betr", 1, "Chillow.StandChillow.Settings.Game.GameSettings");
    g_vmApi = k_gs != nullptr;
    NSLog(@"[SCESP] viewmodel: GameSettings=%p PlayerController.obu=%p FPSCamera.betr=%p", k_gs, mi_obu, mi_betr);
    if (!g_vmApi) g_vmMsg = @"viewmodel: GameSettings class not found";
}

// ---- find the live GameSettings object: bounded walk over reference fields (+ reference arrays), never touches value types ----
struct GsWalk { std::unordered_set<void *> seen; int budget; void *found; };
static void gsWalk(void *obj, int depth, GsWalk &w) {
    if (w.found || w.budget <= 0 || !plausibleObj(obj)) return;
    if (!w.seen.insert(obj).second) return;
    w.budget--;
    void *k = il2_obj_class(obj);
    if (!k) return;
    if (k == k_gs) { w.found = obj; return; }
    if (depth <= 0) return;
    const char *cn = il2_class_name(k);
    if (cn && cn[0] && cn[strlen(cn) - 1] == ']') {                  // array of references only
        void *ek = il2_class_elem ? il2_class_elem(k) : nullptr;
        if (!ek || il2_class_is_vt(ek)) return;
        uintptr_t len = *(uintptr_t *)((char *)obj + 24);
        if (len > 64) len = 64;
        void **el = (void **)((char *)obj + 32);
        for (uintptr_t i = 0; i < len && !w.found; i++) gsWalk(el[i], depth - 1, w);
        return;
    }
    for (void *c = k; c && !w.found; c = il2_class_parent(c)) {
        void *it = nullptr, *f;
        while ((f = il2_class_fields(c, &it))) {
            int fl = il2_field_flags ? il2_field_flags(f) : 0;
            if (fl & 0x10) continue;                                 // static
            void *ft = il2_field_type(f);
            const char *tn = il2_type_name ? il2_type_name(ft) : nullptr;
            if (tn && strstr(tn, "VAR")) continue;
            void *fk = il2_class_from_type(ft);
            if (!fk || il2_class_is_vt(fk)) continue;
            int off = il2_field_offset(f);
            if (off < 16 || off > 0x800) continue;
            gsWalk(*(void **)((char *)obj + off), depth - 1, w);
            if (w.found) return;
        }
    }
}
static void *findGameSettings(void *me) {
    GsWalk w; w.budget = 12000; w.found = nullptr;
    void *game = gameImage();
    if (me) gsWalk(me, 3, w);
    if (!w.found && game) {                                          // live behaviours that usually reference the settings
        static const char *kRoots[][2] = {
            { "Chillow.StandChillow.Cam", "PlayerFPSCamera" },
            { "Chillow.StandChillow.Settings.Game", "GeneralGameSettingsController" },
            { "Chillow.StandChillow.Settings.Game", "GameSettingsController" },
            { "Chillow.StandChillow.Settings", "SettingsController" } };
        for (auto &r : kRoots) {
            void *k = il2_class_from_name(game, r[0], r[1]);
            if (!k || !mi_find) continue;
            std::vector<void *> objs; findObjs(k, objs, 8);
            for (void *o : objs) { gsWalk(o, 3, w); if (w.found) break; }
            if (w.found) break;
        }
    }
    if (!w.found && game && il2_img_count && il2_img_class && il2_static_get) {   // statics of classes with "Settings" in the name
        size_t n = il2_img_count(game);
        for (size_t i = 0; i < n && !w.found; i++) {
            void *k = il2_img_class(game, i);
            const char *cn = k ? il2_class_name(k) : nullptr;
            if (!cn || !strstr(cn, "Settings")) continue;
            void *it = nullptr, *f;
            while ((f = il2_class_fields(k, &it))) {
                int fl = il2_field_flags ? il2_field_flags(f) : 0;
                if (!(fl & 0x10) || (fl & 0x40)) continue;           // need real static storage
                void *ft = il2_field_type(f);
                const char *tn = il2_type_name ? il2_type_name(ft) : nullptr;
                if (tn && strstr(tn, "VAR")) continue;
                void *fk = il2_class_from_type(ft);
                if (!fk || il2_class_is_vt(fk)) continue;
                void *val = nullptr; il2_static_get(f, &val);
                gsWalk(val, 3, w);
                if (w.found) break;
            }
        }
    }
    NSLog(@"[SCESP] viewmodel: GameSettings search -> %p (nodes %d)", w.found, 12000 - w.budget);
    return w.found;
}

// print the readable members of the two enums so the user can tell which number is which
static void dumpEnumField(void *gs, const char *fname, NSMutableString *out) {
    if (!il2_field_name || !il2_static_get) return;
    for (void *k = k_gs; k; k = il2_class_parent(k)) {
        void *it = nullptr, *f;
        while ((f = il2_class_fields(k, &it))) {
            const char *n = il2_field_name(f);
            if (!n || strcmp(n, fname) != 0 || (il2_field_flags(f) & 0x10)) continue;
            void *ek = il2_class_from_type(il2_field_type(f));
            int cur = *(int *)((char *)gs + il2_field_offset(f));
            [out appendFormat:@"%s=%d (%s):", fname, cur, ek ? il2_class_name(ek) : "?"];
            void *it2 = nullptr, *ef; int cnt = 0;
            while (ek && (ef = il2_class_fields(ek, &it2)) && cnt < 8) {
                if (!(il2_field_flags(ef) & 0x10)) continue;
                int v = 0; il2_static_get(ef, &v);
                const char *en = il2_field_name(ef);
                [out appendFormat:@" %s=%d", en ? en : "?", v]; cnt++;
            }
            [out appendString:@"\n"];
            return;
        }
    }
}

static void vmRestore(void *gs, void *cvm) {
    if (!g_vmSaved) return;
    float *pos = (float *)((char *)cvm + g_offPos), *rot = (float *)((char *)cvm + g_offRot);
    for (int i = 0; i < 3; i++) { pos[i] = g_vmOrig[i]; rot[i] = g_vmOrig[3 + i]; }
    *(float *)((char *)cvm + g_offFov) = g_vmOrig[6];
    *(int *)((char *)gs + g_offHands) = g_vmOrigHands;
    *(int *)((char *)gs + g_offFovT) = g_vmOrigFovT;
}

static void applyViewmodel(void *me) {
    bool want = g_set.vm;
    if (!want && !g_vmWasOn) return;
    loadVmApi();
    if (!g_vmApi) return;
    double now = CACurrentMediaTime();
    void *gs = g_gsH ? il2_gc_get(g_gsH) : nullptr;
    if (!gs) {
        if (g_gsH) { il2_gc_free(g_gsH); g_gsH = 0; }
        if (now - g_vmLastFind < 3.0 || !me) return;
        g_vmLastFind = now;
        void *found = findGameSettings(me);
        if (!found) { g_vmMsg = @"viewmodel: GameSettings not found, retrying every 3s (see log)"; return; }
        g_gsH = il2_gc_new(found, 0);
        gs = found; g_vmSaved = false; g_offCvm = -1;
        NSMutableString *e = [NSMutableString string];
        dumpEnumField(gs, "HandsPositionType", e); dumpEnumField(gs, "FieldOfViewType", e);
        g_vmEnums = e; NSLog(@"[SCESP] viewmodel enums:\n%@", e);
    }
    if (g_offCvm < 0) {                                              // resolve field offsets once per found object
        g_offCvm   = fieldOffByName(k_gs, "CustomViewModel");   if (g_offCvm   < 0) g_offCvm = 0x20;
        g_offHands = fieldOffByName(k_gs, "HandsPositionType"); if (g_offHands < 0) g_offHands = 0x2C;
        g_offFovT  = fieldOffByName(k_gs, "FieldOfViewType");   if (g_offFovT  < 0) g_offFovT = 0x1C;
    }
    void *cvm = *(void **)((char *)gs + g_offCvm);
    if (!plausibleObj(cvm)) { g_vmMsg = @"viewmodel: CustomViewModel is null in this settings object"; return; }
    if (!k_cvm) {
        k_cvm = il2_obj_class(cvm);
        g_offPos = fieldOffByName(k_cvm, "PositionOffset"); if (g_offPos < 0) g_offPos = 0x10;
        g_offRot = fieldOffByName(k_cvm, "RotationOffset"); if (g_offRot < 0) g_offRot = 0x1C;
        g_offFov = fieldOffByName(k_cvm, "AdditiveFov");    if (g_offFov < 0) g_offFov = 0x28;
        NSLog(@"[SCESP] viewmodel offsets: cvm=0x%x hands=0x%x fovT=0x%x pos=0x%x rot=0x%x fov=0x%x", g_offCvm, g_offHands, g_offFovT, g_offPos, g_offRot, g_offFov);
    }
    float *pos = (float *)((char *)cvm + g_offPos), *rot = (float *)((char *)cvm + g_offRot);
    if (!g_vmSaved) {
        for (int i = 0; i < 3; i++) { g_vmOrig[i] = pos[i]; g_vmOrig[3 + i] = rot[i]; }
        g_vmOrig[6] = *(float *)((char *)cvm + g_offFov);
        g_vmOrigHands = *(int *)((char *)gs + g_offHands); g_vmOrigFovT = *(int *)((char *)gs + g_offFovT);
        g_vmSaved = true;
    }
    bool newMe = me && me != g_vmLastMe;
    bool due = g_vmForce || newMe || (++g_vmTick % 90) == 0;
    if (!due) return;
    g_vmForce = false;
    if (want) {
        for (int i = 0; i < 3; i++) { pos[i] = g_set.vmv[i]; rot[i] = g_set.vmv[3 + i]; }
        *(float *)((char *)cvm + g_offFov) = g_set.vmv[6];
        int hands = (int)lroundf(g_set.vmv[7]), fovT = (int)lroundf(g_set.vmv[8]);
        if (hands >= 0) *(int *)((char *)gs + g_offHands) = hands; else *(int *)((char *)gs + g_offHands) = g_vmOrigHands;
        if (fovT >= 0)  *(int *)((char *)gs + g_offFovT) = fovT;   else *(int *)((char *)gs + g_offFovT) = g_vmOrigFovT;
        g_vmWasOn = true;
        g_vmMsg = [NSString stringWithFormat:@"viewmodel: ON  gs=%p obu=%s\n%@", gs, mi_obu ? "ok" : "missing", g_vmEnums];
    } else {
        vmRestore(gs, cvm);
        g_vmWasOn = false;
        g_vmMsg = @"viewmodel: off (originals restored)";
    }
    if (me) {
        g_vmLastMe = me;
        if (mi_obu) { void *args[1] = { gs }; inv(mi_obu, me, args); }
        if (mi_betr && k_fpscam && mi_find) {
            std::vector<void *> cams; findObjs(k_fpscam, cams, 4);
            for (void *c : cams) { void *args[1] = { gs }; inv(mi_betr, c, args); }
        }
    }
}

// ---- no spread (v5.9) --------------------------------------------------------------------------------------------
// Static metadata dump (global-metadata.dat, v31), Chillow.StandChillow.Inventory.Gun:
//   GunParameters { _accuracyAdditiveCurve, _accuracyMultOnJump, _additiveNoAimDispertionCurve, _accuracyMultOnCrouch,
//                   _accuracyAimMult, _accuracyAimMultOnCrouch, _recoilParameters, ... }
//   RecoilParameters { horizontalRange, verticalRange, xAxisDeviation, yAxisDeviation, ..., relativeDispertionCurve, ... }
// Everything is looked up by NAME and TYPE at runtime (no offsets). Recoil kick itself is not touched here (that is _recoilControl /
// xAxisDeviation / yAxisDeviation, a separate feature); this only flattens the accuracy cone.
// Gate (computed by the caller each tick): at least one other character and ALL of them are bots = offline bot match.
// Not run on a device by me. If the status line says "0 slots", send me the [SCESP] nospread log lines.
struct NsSlot { uint32_t owner; int off; uint8_t kind; uint32_t hOrig; float origF; };   // kind 0 = float, 1 = AnimationCurve
static std::vector<NsSlot> g_nsSlots;
static std::unordered_set<void *> g_nsSeen;
static void *k_nsGP, *k_nsAC, *mi_nsConst;
static uint32_t g_nsZero = 0;                // gchandle of the shared flat AnimationCurve
static bool g_nsTried = false, g_nsActive = false;
static double g_nsLastScan = 0;
static int g_nsObs = 0, g_nsParams = 0;
static NSString *g_nsMsg = @"no spread: off";

static void nsInit() {
    if (g_nsTried) return;
    g_nsTried = true;
    loadVmApi();                                                   // object_get_class etc.
    void *game = gameImage(), *core = findImage("UnityEngine.CoreModule.dll");
    if (game) k_nsGP = il2_class_from_name(game, "Chillow.StandChillow.Inventory.Gun", "GunParameters");
    if (core) k_nsAC = il2_class_from_name(core, "UnityEngine", "AnimationCurve");
    if (k_nsAC) mi_nsConst = il2_get_method(k_nsAC, "Constant", 3);
    NSLog(@"[SCESP] nospread: GunParameters=%p AnimationCurve=%p Constant=%p", k_nsGP, k_nsAC, mi_nsConst);
}
static void *nsFlatCurve() {
    void *c = g_nsZero ? il2_gc_get(g_nsZero) : nullptr;
    if (c) return c;
    if (!mi_nsConst) return nullptr;
    float a = 0.f, b = 1.f, v = 0.f;
    void *args[3] = { &a, &b, &v };
    c = inv(mi_nsConst, nullptr, args);
    if (c) g_nsZero = il2_gc_new(c, 0);
    return c;
}
// GunParameters is a plain class on some builds and a ScriptableObject on others: try the Unity object search first,
// then walk the reference fields of every GunController (two hops) and keep whatever has exactly the GunParameters class.
static void nsWalkRefs(void *obj, int depth, std::vector<void *> &out, std::unordered_set<void *> &vis) {
    if (!obj || depth < 0 || !il2_obj_class || !vis.insert(obj).second) return;
    for (void *k = il2_obj_class(obj); k; k = il2_class_parent(k)) {
        void *it = nullptr, *f;
        while ((f = il2_class_fields(k, &it))) {
            if (il2_field_flags(f) & 0x10) continue;
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            if (!tn || strncmp(tn, "Chillow.StandChillow.", 21) != 0) continue;
            void *fk = il2_class_from_type(ft);
            if (!fk || (il2_class_is_vt && il2_class_is_vt(fk))) continue;
            void *p = *(void **)((char *)obj + il2_field_offset(f));
            if (!plausibleObj(p)) continue;
            if (il2_obj_class(p) == k_nsGP) { if (vis.insert(p).second) out.push_back(p); }
            else nsWalkRefs(p, depth - 1, out, vis);
        }
    }
}
static void nsFindParams(std::vector<void *> &out) {
    std::vector<void *> v;
    if (mi_find && k_nsGP) findObjs(k_nsGP, v, 512);
    for (void *o : v) out.push_back(o);
    if (!out.empty() || !mi_find) return;
    void *game = gameImage();
    void *kgc = game ? il2_class_from_name(game, "Chillow.StandChillow.Inventory.Gun", "GunController") : nullptr;
    if (!kgc) return;
    std::vector<void *> gcs; findObjs(kgc, gcs, 256);
    std::unordered_set<void *> vis;
    for (void *g : gcs) nsWalkRefs(g, 2, out, vis);
}
static void nsAddSlot(void *owner, int off, uint8_t kind) {
    NsSlot s{}; s.owner = il2_gc_new(owner, 0); s.off = off; s.kind = kind;
    char *a = (char *)owner + off;
    if (kind == 0) s.origF = *(float *)a;
    else { void *c = *(void **)a; s.hOrig = c ? il2_gc_new(c, 0) : 0; }
    g_nsSlots.push_back(s);
}
static void nsScanOne(void *gp) {
    static const char *kF[] = { "_accuracyMultOnJump", "_accuracyMultOnCrouch", "_accuracyAimMult", "_accuracyAimMultOnCrouch" };
    static const char *kC[] = { "_accuracyAdditiveCurve", "_additiveNoAimDispertionCurve" };
    for (void *k = il2_obj_class(gp); k; k = il2_class_parent(k)) {
        void *it = nullptr, *f;
        while ((f = il2_class_fields(k, &it))) {
            if (il2_field_flags(f) & 0x10) continue;
            const char *fn = il2_field_name(f);
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            if (!fn || !tn) continue;
            int off = il2_field_offset(f);
            for (const char *n : kF) if (!strcmp(fn, n)) {
                if (!strcmp(tn, "System.Single")) nsAddSlot(gp, off, 0);
                else { g_nsObs++; NSLog(@"[SCESP] nospread: %s is %s (not a plain float), skipped", fn, tn); }
            }
            for (const char *n : kC) if (!strcmp(fn, n)) {
                if (!strcmp(tn, "UnityEngine.AnimationCurve")) nsAddSlot(gp, off, 1);
                else NSLog(@"[SCESP] nospread: %s is %s (not an AnimationCurve), skipped", fn, tn);
            }
            if (!strcmp(fn, "_recoilParameters")) {
                void *rk = il2_class_from_type(ft);
                int co = rk ? fieldOffByName(rk, "relativeDispertionCurve") : -1;
                if (co < 0) continue;
                if (il2_class_is_vt && il2_class_is_vt(rk)) nsAddSlot(gp, off + co - 16, 1);          // inline struct: its field offsets include the 0x10 box header
                else { void *rp = *(void **)((char *)gp + off); if (plausibleObj(rp)) nsAddSlot(rp, co, 1); }
            }
        }
    }
}
static void nsRestore() {
    for (auto &s : g_nsSlots) {
        char *o = (char *)il2_gc_get(s.owner);
        if (o) {
            if (s.kind == 0) *(float *)(o + s.off) = s.origF;
            else { void *c = s.hOrig ? il2_gc_get(s.hOrig) : nullptr; if (c) *(void **)(o + s.off) = c; }
        }
        il2_gc_free(s.owner);
        if (s.hOrig) il2_gc_free(s.hOrig);
    }
    g_nsSlots.clear(); g_nsSeen.clear(); g_nsParams = 0; g_nsObs = 0;
}
static void nsAssert() {
    void *flat = nullptr;
    for (auto &s : g_nsSlots) {
        char *o = (char *)il2_gc_get(s.owner);
        if (!o) continue;
        if (s.kind == 0) { float *p = (float *)(o + s.off); if (*p != 0.f) *p = 0.f; }
        else { if (!flat) flat = nsFlatCurve(); if (flat) *(void **)(o + s.off) = flat; }
    }
}
// me = local PlayerController (or null), want = toggle, offline = every other character is a bot
static void applyNoSpread(void *me, bool want, bool offline) {
    bool active = want && offline && me;
    if (!active) {
        if (g_nsActive) { nsRestore(); g_nsActive = false; NSLog(@"[SCESP] nospread: restored"); }
        g_nsMsg = !want ? @"no spread: off" : @"no spread: waiting (offline match with bots only)";
        return;
    }
    nsInit();
    if (!k_nsGP || !il2_obj_class) { g_nsMsg = @"no spread: GunParameters class not found"; return; }
    double now = CACurrentMediaTime();
    if (!g_nsActive || now - g_nsLastScan > 2.0) {                   // weapons load lazily, so look again every 2 s
        g_nsLastScan = now;
        std::vector<void *> gps; nsFindParams(gps);
        size_t before = g_nsSlots.size();
        for (void *gp : gps) if (g_nsSeen.insert(gp).second) { g_nsParams++; nsScanOne(gp); }
        if (g_nsSlots.size() != before) NSLog(@"[SCESP] nospread: %d GunParameters, %zu slots", g_nsParams, g_nsSlots.size());
        g_nsActive = true;
    }
    if (g_nsSlots.empty()) { g_nsMsg = [NSString stringWithFormat:@"no spread: 0 slots (%d params, %d obscured), retrying", g_nsParams, g_nsObs]; return; }
    nsAssert();                                                      // every tick: the game may re-apply its own values (cheap: writes only on change)
    g_nsMsg = [NSString stringWithFormat:@"no spread: ON  %d params, %zu fields%s", g_nsParams, g_nsSlots.size(), g_nsObs ? " (some obscured, skipped)" : ""];
}

// ---- stretched resolution ----------------------------------------------------------------------------------------
static void *mi_setres = nullptr;
static bool g_stTried = false, g_stOn = false;
static int g_natW = 0, g_natH = 0, g_stTries = 0;
static double g_stLast = 0;
static NSString *g_stMsg = @"stretch: off";
static void applyStretch(int sw, int sh) {
    if (!g_set.stretch && !g_stOn) return;
    if (!g_stTried) {
        g_stTried = true;
        void *core = findImage("UnityEngine.CoreModule.dll");
        void *cScreen = core ? il2_class_from_name(core, "UnityEngine", "Screen") : nullptr;
        void *it = nullptr, *m;
        while (cScreen && (m = il2_class_methods(cScreen, &it))) {   // SetResolution(int,int,bool); the FullScreenMode overload is skipped
            if (strcmp(il2_method_name(m), "SetResolution") != 0 || il2_method_pcount(m) != 3) continue;
            const char *t2 = il2_type_name(il2_method_param(m, 2));
            if (t2 && strcmp(t2, "System.Boolean") == 0) { mi_setres = m; break; }
        }
        NSLog(@"[SCESP] stretch: Screen.SetResolution(int,int,bool) = %p", mi_setres);
    }
    if (!mi_setres) { g_stMsg = @"stretch: Screen.SetResolution not found"; return; }
    if (!g_stOn) { g_natW = sw; g_natH = sh; }                         // remember the native size before the first change
    if (g_natW <= 0 || g_natH <= 0) return;
    int tw = g_natW, th = g_natH;
    if (g_set.stretch) {
        tw = (int)lroundf(th * g_set.stretchAspect);
        if (tw > g_natW) tw = g_natW;
        if (tw < 320) tw = 320;
    }
    double now = CACurrentMediaTime();
    if ((sw != tw || sh != th) && now - g_stLast > 0.5 && g_stTries < 6) {
        g_stLast = now; g_stTries++;
        bool fs = true;
        void *args[3] = { &tw, &th, &fs };
        inv(mi_setres, nullptr, args);
        NSLog(@"[SCESP] stretch: SetResolution(%d,%d) from %dx%d (try %d)", tw, th, sw, sh, g_stTries);
    }
    if (sw == tw && sh == th) g_stTries = 0;
    g_stOn = g_set.stretch || !(sw == g_natW && sh == g_natH);
    if (!g_set.stretch && sw == g_natW && sh == g_natH) g_stOn = false;
    g_stMsg = g_set.stretch
        ? [NSString stringWithFormat:@"stretch: %dx%d (native %dx%d)%@", sw, sh, g_natW, g_natH, g_stTries >= 6 ? @"\ndevice/game keeps overriding it" : @""]
        : @"stretch: off";
}

static void rescan(bool wantBones) {
    std::vector<void *> objs;
    for (int t = 0; t < kN; t++) g_counts[t] = 0;
    for (uint32_t h : g_aimH) il2_gc_free(h);
    g_aimH.clear();
    if (k_aim) { std::vector<void *> ao; findObjs(k_aim, ao, 32); for (void *x : ao) g_aimH.push_back(il2_gc_new(x, 0)); }
    if (g_active >= 0 && k_targets[g_active]) g_counts[g_active] = findObjs(k_targets[g_active], objs, 64);
    if (objs.empty()) {
        for (int t = 0; t < kN; t++) {
            if (!k_targets[t]) continue;
            g_counts[t] = findObjs(k_targets[t], objs, 64);
            if (g_counts[t] > 0) { if (g_active != t) { g_active = t; findTeamFields(k_targets[t]); } break; }
        }
    }

    std::vector<PlayerInfo> fresh(objs.size());
    for (size_t i = 0; i < objs.size(); i++) fresh[i].obj = il2_gc_new(objs[i], 0);

    if (wantBones && k_smr && mi_get_bones && d_parent && !objs.empty()) {
        // ancestors (self, parent, grandparent) of every player; unique ones identify the owner
        struct Anc { void *tr; int pl; int cnt; };
        std::vector<Anc> anc;
        for (size_t i = 0; i < objs.size(); i++) {
            void *tr = d_tr(objs[i], mi_tr);
            for (int lvl = 0; lvl < 3 && tr; lvl++) {
                bool found = false;
                for (auto &a : anc) if (a.tr == tr) { a.cnt++; found = true; break; }
                if (!found) anc.push_back({tr, (int)i, 1});
                tr = d_parent(tr, mi_parent);
            }
        }
        auto ownerOf = [&](void *comp) -> int {
            void *tr = d_tr(comp, mi_tr);
            for (int depth = 0; depth < 20 && tr; depth++) {
                for (auto &a : anc) if (a.tr == tr && a.cnt == 1) return a.pl;
                tr = d_parent(tr, mi_parent);
            }
            return -1;
        };
        std::vector<void *> smrs;
        findObjs(k_smr, smrs, 512);
        std::vector<std::vector<void *>> mine(objs.size());
        for (void *smr : smrs) { int o = ownerOf(smr); if (o >= 0) mine[o].push_back(smr); }
        std::vector<std::vector<void *>> animsOf(objs.size());
        if (k_animator) {
            std::vector<void *> anims;
            findObjs(k_animator, anims, 512);
            for (void *an : anims) { int o = ownerOf(an); if (o >= 0) animsOf[o].push_back(an); }
        }
        if (g_hpRoots) {
            for (size_t i = 0; i < objs.size(); i++) fresh[i].hproot.assign(kHpRoots, 0);
            for (int r = 1; r < kHpRoots; r++) {
                if (!k_hpRoot[r]) continue;
                std::vector<void *> ro;
                findObjs(k_hpRoot[r], ro, 128);
                for (void *x : ro) { int o = ownerOf(x); if (o >= 0 && !fresh[o].hproot[r]) fresh[o].hproot[r] = il2_gc_new(x, 0); }
            }
        }
        for (size_t i = 0; i < objs.size(); i++) {
            void *best = nullptr, *bestSmr = nullptr; uintptr_t bestN = 0;
            for (void *smr : mine[i]) {
                fresh[i].smr.push_back(il2_gc_new(smr, 0));
                void *arr = inv(mi_get_bones, smr, nullptr);
                uintptr_t n = arr ? *(uintptr_t *)((char *)arr + 24) : 0;
                if (n > bestN) { bestN = n; best = arr; bestSmr = smr; }
            }
            for (void *an : animsOf[i]) fresh[i].anim.push_back(il2_gc_new(an, 0));
            if (bestSmr) fresh[i].body = il2_gc_new(bestSmr, 0);
            if (!best) continue;
            if (bestN > 160) bestN = 160;
            void **bones = (void **)((char *)best + 32);
            std::vector<void *> bp;
            for (uintptr_t b = 0; b < bestN; b++) {
                bp.push_back(bones[b]);
                fresh[i].bone.push_back(bones[b] ? il2_gc_new(bones[b], 0) : 0);
                fresh[i].skip.push_back(bones[b] ? (char)boneNameSkip(bones[b]) : 1);
                fresh[i].part.push_back(bones[b] ? boneAimPart(bones[b]) : (int8_t)-1);
            }
            for (uintptr_t b = 0; b < bestN; b++) {
                int pi = -1;
                if (bp[b]) {
                    void *par = d_parent(bp[b], mi_parent);
                    for (uintptr_t c = 0; c < bestN && par; c++) if (bp[c] == par) { pi = (int)c; break; }
                }
                fresh[i].parent.push_back(pi);
            }
        }
    }
    for (auto &p : g_pl) freeInfo(p);
    g_pl.swap(fresh);
}

// ---- health bar ------------------------------------------------------------------------
// The game uses Anti-Cheat Toolkit, so health is most likely an ObscuredFloat / ObscuredInt (XOR-ed
// storage). Those are read by calling the game's own op_Implicit, i.e. exactly what its code does.
// Candidates = float / int / ObscuredFloat / ObscuredInt instance fields of the player class AND of the
// hit / network components that sit on the same character (roots), reachable through up to two
// reference hops (inline structs are followed too).
// Learn: snapshot all characters, user damages one, compare: the right field dropped on exactly one
// character and did not move on any other.
static const char *kObsF = "CodeStage.AntiCheat.ObscuredTypes.ObscuredFloat";
static const char *kObsI = "CodeStage.AntiCheat.ObscuredTypes.ObscuredInt";
struct HCand { uint8_t kind, nd, root; int off[3]; const char *n1, *n2; };   // kind 0 float, 1 int, 2 ObscuredFloat, 3 ObscuredInt
static std::vector<HCand> g_hc;
static HCand g_hpC = { 0, 0, 0, { 0, 0, 0 }, nullptr, nullptr };
static bool g_haveHp = false;
static int g_hpLearn = 0;                 // 0 idle, 1 snapshot taken (waiting for the hit)
static float g_hpRef = 0;                 // "full health" reference = highest value seen on the learned field
static NSString *g_hpMsg = @"hp: not learned";
static double g_hpMsgUntil = 0;
static std::unordered_map<void *, std::vector<float>> g_hpSnap;
static void *mi_obsF, *mi_obsI;
static size_t g_hcObs = 0;
static int g_scanRoot = 0;

// finds ObscuredFloat / ObscuredInt in whatever assembly holds ACTk and resolves their implicit conversions
static bool g_obsTried = false;
static void ensureObs() {
    if (g_obsTried || !il2_domain_get) return;
    g_obsTried = true;
    size_t n = 0;
    void **asms = il2_get_assemblies(il2_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2_asm_image(asms[i]);
        if (!img) continue;
        void *kf = il2_class_from_name(img, "CodeStage.AntiCheat.ObscuredTypes", "ObscuredFloat");
        void *ki = il2_class_from_name(img, "CodeStage.AntiCheat.ObscuredTypes", "ObscuredInt");
        if (kf && !mi_obsF) mi_obsF = findMethod(kf, "op_Implicit", 1, kObsF);
        if (ki && !mi_obsI) mi_obsI = findMethod(ki, "op_Implicit", 1, kObsI);
    }
    NSLog(@"[SCESP] obscured: float op=%p int op=%p", mi_obsF, mi_obsI);
}
static PlayerInfo *piFor(void *obj) {
    for (auto &pi : g_pl) if (il2_gc_get(pi.obj) == obj) return &pi;
    return nullptr;
}
static bool readCand(const HCand &c, void *playerObj, PlayerInfo *pi, float &out) {
    char *o = (char *)playerObj;
    if (c.root) {
        if (!pi || c.root >= pi->hproot.size() || !pi->hproot[c.root]) return false;
        o = (char *)il2_gc_get(pi->hproot[c.root]);
        if (!o || !alive(o)) return false;
    }
    if (!o) return false;
    for (int i = 0; i < c.nd; i++) { o = *(char **)(o + c.off[i]); if (!o) return false; }
    char *addr = o + c.off[c.nd];
    switch (c.kind) {
        case 0: out = *(float *)addr; break;
        case 1: out = (float)*(int *)addr; break;
        case 2: case 3: {
            if (!g_obsTried) ensureObs();
            void *mi = c.kind == 2 ? mi_obsF : mi_obsI;
            if (!mi) return false;
            void *args[1] = { addr };                 // value-type parameter = pointer to the struct data
            void *r = inv(mi, nullptr, args);         // boxed result
            if (!r) return false;
            out = c.kind == 2 ? *(float *)((char *)r + 16) : (float)*(int *)((char *)r + 16);
            break;
        }
        default: return false;
    }
    return out == out;
}
static bool isBotObj(void *o) { return o && *(void **)((char *)o + kOffBot) != nullptr; }
static void *localAim(void *me) {                       // exact local AimController, validated by its back-reference
    if (!me) return nullptr;
    void *a = *(void **)((char *)me + kOffAim);
    return (a && *(void **)((char *)a + 0xC8) == me) ? a : nullptr;
}
static std::unordered_map<void *, float> g_hpMax;
// ---- floating damage numbers ----
struct DmgPop { void *id; V3 pos; float amount; double t0; };
struct DmgDraw { CGPoint p; float a, amt, k; };
// value text inside a bar: x = bar centre, y = bar top; side<0 = hp bar, side>0 = armor bar
struct BarTxt { CGFloat x, y; int v, side; float ratio; };
struct WepTxt { CGFloat x, y; char s[24]; };
static std::vector<DmgPop> g_pops;
static std::unordered_map<void *, float> g_hpPrev;      // last HP seen per character; a drop = damage taken
static void dmgSpawn(void *id, V3 pos, float amt, double now) {
    for (auto &d : g_pops) if (d.id == id && now - d.t0 < 0.25) { d.amount += amt; d.t0 = now; d.pos = pos; return; }   // burst fire -> one growing number
    if (g_pops.size() >= 10) g_pops.erase(g_pops.begin());
    g_pops.push_back({ id, pos, amt, now });
}
// HP straight from the game's own getter (works for every character at any time), learned field only as a fallback
static bool readHp(void *obj, PlayerInfo *pi, float &out) {
    if (mi_hp && obj) {
        void *b = inv(mi_hp, obj, nullptr);
        if (b) { int v = *(int *)((char *)b + 16); if (v >= 0 && v < 100000) { out = (float)v; return true; } }
    }
    if (g_haveHp) return readCand(g_hpC, obj, pi, out);
    return false;
}
// Armor from the game's own HUD getters (same keyed-container path as ode(), see v24 notes):
// odf() -> Int32 armor value (0 when the lookup fails), odg() -> Boolean armor state used by the HUD armor icon.
static bool readArmor(void *obj, int &armor, bool &flag) {
    armor = 0; flag = false;
    if (!obj || !mi_armor) return false;
    void *b = inv(mi_armor, obj, nullptr);
    if (!b) return false;
    int v = *(int *)((char *)b + 16);
    if (v < 0 || v > 100000) return false;
    armor = v;
    if (mi_helm) { void *h = inv(mi_helm, obj, nullptr); if (h) flag = *(bool *)((char *)h + 16); }
    return true;
}
// Weapon in the character's hands, from the static dump (StandChillow 2.07):
//   PlayerController +0xD8 WeaponryController -> +0x98 WeaponController -> +0xA8 WeaponParameters -> +0x28 _shortName (string)
// Every hop is range-checked before it is dereferenced; any miss just means "no label".
static const int kOffWeaponry = 0xD8, kOffWepCur = 0x98, kOffWepPar = 0xA8, kOffWepShort = 0x28;
static inline bool okPtr(void *p) { uintptr_t v = (uintptr_t)p; return v > 0x100000000ULL && v < 0x800000000000ULL && (v & 7) == 0; }
static bool readWeaponName(void *obj, char *out, size_t cap) {
    out[0] = 0;
    if (!okPtr(obj)) return false;
    void *wy = *(void **)((char *)obj + kOffWeaponry);   if (!okPtr(wy)) return false;
    void *wc = *(void **)((char *)wy + kOffWepCur);      if (!okPtr(wc)) return false;
    void *wp = *(void **)((char *)wc + kOffWepPar);      if (!okPtr(wp)) return false;
    void *st = *(void **)((char *)wp + kOffWepShort);    if (!okPtr(st)) return false;
    int len = *(int *)((char *)st + 0x10);               // il2cpp string: length @+0x10, UTF-16 chars @+0x14
    if (len <= 0 || len > 32) return false;
    const uint16_t *ch = (const uint16_t *)((char *)st + 0x14);
    size_t n = 0;
    for (int i = 0; i < len && n + 1 < cap; i++) {
        uint16_t c = ch[i];
        if (c < 0x20 || c > 0x7E) return (out[n] = 0, false);   // not plain text -> wrong object, show nothing
        out[n++] = (char)c;
    }
    out[n] = 0;
    return n > 0;
}
static NSString *hpName(const HCand &c) {
    static const char *kn[] = { "float", "int", "obsF", "obsI" };
    return [NSString stringWithFormat:@"r%d %s %s%s%s nd=%d off=%d/%d/%d", c.root, kn[c.kind & 3], c.n1 ? c.n1 : "", c.n1 ? "." : "", c.n2 ? c.n2 : "?", c.nd, c.off[0], c.off[1], c.off[2]];
}
static void scanHpClass(void *klass, int nd, const int *path, int adj, int inl, const char *hop) {
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            void *ft = il2_field_type(f);
            const char *tn = ft ? il2_type_name(ft) : nullptr;
            if (!tn) continue;
            int off = adj + il2_field_offset(f);
            const char *fn = il2_field_name ? il2_field_name(f) : "?";
            if (!strcmp(fn, "value__")) continue;
            int kind = -1;
            if (!strcmp(tn, "System.Single")) kind = 0;
            else if (!strcmp(tn, "System.Int32")) kind = 1;
            else if (!strcmp(tn, kObsF)) kind = 2;
            else if (!strcmp(tn, kObsI)) kind = 3;
            if (kind >= 0) {
                if (kind == 2 && !mi_obsF && il2_class_from_type) { void *ok = il2_class_from_type(ft); if (ok) mi_obsF = findMethod(ok, "op_Implicit", 1, kObsF); }
                if (kind == 3 && !mi_obsI && il2_class_from_type) { void *ok = il2_class_from_type(ft); if (ok) mi_obsI = findMethod(ok, "op_Implicit", 1, kObsI); }
                if ((kind == 2 && !mi_obsF) || (kind == 3 && !mi_obsI)) continue;
                if (g_hc.size() >= 60000) continue;
                HCand c; c.kind = (uint8_t)kind; c.nd = (uint8_t)nd; c.root = (uint8_t)g_scanRoot; c.n1 = hop; c.n2 = fn;
                c.off[0] = c.off[1] = c.off[2] = 0;
                for (int i = 0; i < nd; i++) c.off[i] = path[i];
                c.off[nd] = off;
                if (kind >= 2) g_hcObs++;
                g_hc.push_back(c);
            } else if (il2_class_from_type && il2_class_is_vt && !strncmp(tn, "Chillow.StandChillow.", 21)) {
                void *nk = il2_class_from_type(ft);
                if (!nk) continue;
                if (il2_class_is_vt(nk)) { if (inl < 2) scanHpClass(nk, nd, path, off - 16, inl + 1, hop ? hop : fn); }
                else if (nd < 2) { int np[3] = { path[0], path[1], path[2] }; np[nd] = off; scanHpClass(nk, nd + 1, np, 0, 0, hop ? hop : fn); }
            }
        }
    }
}
static void saveHp() {
    if (!g_haveHp) return;
    [NSUserDefaults.standardUserDefaults setObject:@[@(g_hpC.kind), @(g_hpC.nd), @(g_hpC.off[0]), @(g_hpC.off[1]), @(g_hpC.off[2]), @(g_hpC.root), @(g_hpRef)] forKey:@"scesp_hpc3"];
}
static void loadHp() {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:@"scesp_hpc3"];
    if (a.count != 7) return;
    g_hpC.kind = [a[0] intValue]; g_hpC.nd = [a[1] intValue];
    g_hpC.off[0] = [a[2] intValue]; g_hpC.off[1] = [a[3] intValue]; g_hpC.off[2] = [a[4] intValue];
    g_hpC.root = [a[5] intValue];
    g_hpRef = [a[6] floatValue]; g_haveHp = true; g_hpRoots = g_hpC.root > 0; g_hpMsg = @"hp: learned field loaded";
}
static void hpSay(NSString *m, double secs) { g_hpMsg = m; g_hpMsgUntil = CACurrentMediaTime() + secs; NSLog(@"[SCESP] %@", m); }

// returns true when the button should show the "waiting for hit" caption
static bool hpLearnTap() {
    if (g_hpLearn == 0) {
        if (g_active < 0 || !k_targets[g_active]) { hpSay(@"hp: no player class yet", 5); return false; }
        g_hpRoots = true;
        rescan(true);                                     // collect the hit / network components per player now
        ensureObs();
        g_hc.clear(); g_hpSnap.clear(); g_hcObs = 0;
        int path[3] = { 0, 0, 0 };
        int rootsUsed = 0;
        for (int r = 0; r < kHpRoots; r++) {
            void *kl = r == 0 ? k_targets[g_active] : k_hpRoot[r];
            if (!kl) continue;
            if (r > 0) { bool any = false; for (auto &pi : g_pl) if (r < (int)pi.hproot.size() && pi.hproot[r]) { any = true; break; } if (!any) continue; rootsUsed++; }
            g_scanRoot = r;
            scanHpClass(kl, 0, path, 0, 0, nullptr);
        }
        for (auto &pi : g_pl) {
            void *o = il2_gc_get(pi.obj);
            if (!alive(o)) continue;
            std::vector<float> v(g_hc.size(), NAN);
            for (size_t i = 0; i < g_hc.size(); i++) { float x; if (readCand(g_hc[i], o, &pi, x)) v[i] = x; }
            g_hpSnap[o] = std::move(v);
        }
        if (g_hpSnap.size() < 2) { hpSay(@"hp: need 2+ characters in the scene", 6); return false; }
        g_hpLearn = 1;
        hpSay([NSString stringWithFormat:@"hp: %zuf %zuobs R%d - hit 1 enemy, tap", g_hc.size(), g_hcObs, rootsUsed], 600);
        return true;
    }
    g_hpLearn = 0;
    std::unordered_map<void *, PlayerInfo *> pim;
    for (auto &pi : g_pl) pim[il2_gc_get(pi.obj)] = &pi;
    int best = -1, bestScore = -1; size_t matches = 0; float bestBefore = 0;
    for (size_t i = 0; i < g_hc.size(); i++) {
        int dec = 0; bool bad = false; float before = 0;
        for (auto &kv : g_hpSnap) {
            if (!alive(kv.first)) continue;
            float b = kv.second[i], a;
            auto it = pim.find(kv.first);
            if (b != b || !readCand(g_hc[i], kv.first, it == pim.end() ? nullptr : it->second, a)) continue;
            float d = a - b;
            if (d < -0.5f && b > 0.5f && b < 100000.f && a >= -1.f) { dec++; before = b; }
            else if (fabsf(d) > 0.001f) { bad = true; break; }
        }
        if (bad || dec != 1) continue;
        matches++;
        int score = 0;                                      // fields where everyone started on the same value look like "full health"
        for (auto &kv : g_hpSnap) if (kv.second[i] == before) score++;
        if (score > bestScore) { bestScore = score; best = (int)i; bestBefore = before; }
    }
    if (best < 0) {
        // report: everything that dropped on at least one character, to see what the game really changed
        NSMutableString *rp = [NSMutableString stringWithFormat:@"hp learn FAILED: cands=%zu obs=%zu chars=%zu\n", g_hc.size(), g_hcObs, g_hpSnap.size()];
        for (int r = 1; r < kHpRoots; r++) { int n = 0; for (auto &pi : g_pl) if (r < (int)pi.hproot.size() && pi.hproot[r]) n++; [rp appendFormat:@"root %d (%s): on %d players\n", r, kHpRootDefs[r].name, n]; }
        int shown = 0;
        for (size_t i = 0; i < g_hc.size() && shown < 40; i++) {
            for (auto &kv : g_hpSnap) {
                if (!alive(kv.first)) continue;
                float b = kv.second[i], a;
                auto it = pim.find(kv.first);
                if (b != b || !readCand(g_hc[i], kv.first, it == pim.end() ? nullptr : it->second, a)) continue;
                if (a - b < -0.001f) { [rp appendFormat:@"%@  %.2f -> %.2f\n", hpName(g_hc[i]), b, a]; shown++; break; }
            }
        }
        UIPasteboard.generalPasteboard.string = rp;
        NSLog(@"[SCESP] %@", rp);
        hpSay(@"hp: no match, report copied. hit ENEMY once", 12);
        g_hpSnap.clear();
        return false;
    }
    g_hpC = g_hc[best]; g_haveHp = true; g_hpRoots = g_hpC.root > 0;
    float ref = bestBefore;
    for (auto &kv : g_hpSnap) if (kv.second[best] == kv.second[best] && kv.second[best] > ref) ref = kv.second[best];
    g_hpRef = ref;
    saveHp();
    UIPasteboard.generalPasteboard.string = hpName(g_hpC);
    hpSay([NSString stringWithFormat:@"hp OK r%d %s full=%.0f (%zu)", g_hpC.root, g_hpC.kind >= 2 ? "obscured" : (g_hpC.kind ? "int" : "float"), g_hpRef, matches], 10);
    g_hpSnap.clear();
    return false;
}

// ---- occlusion override ----------------------------------------------------------------
// The game hides occluded characters itself (OcclusionSystem -> ObjectOccludee), and animators of
// hidden models stop updating (that is the T-pose). Turn that system off while skeleton/chams are on.
static std::vector<uint32_t> g_occ;
static bool g_occOff = false;

static void setOcclusion(bool disabled) {
    for (uint32_t h : g_occ) il2_gc_free(h);
    g_occ.clear();
    if (k_occsys) {
        std::vector<void *> o;
        findObjs(k_occsys, o, 8);
        for (void *x : o) g_occ.push_back(il2_gc_new(x, 0));
    }
    bool en = !disabled;
    for (uint32_t h : g_occ) {
        void *x = il2_gc_get(h);
        if (alive(x)) { void *a[1] = { &en }; inv(mi_beh_enabled, x, a); }
    }
    void *cam = d_cam_main(mi_cam_main);
    if (cam && alive(cam)) { bool u = !disabled; void *a[1] = { &u }; inv(mi_cam_occ, cam, a); if (ic_cam_set_occ) ic_cam_set_occ(cam, u); }
    g_occOff = disabled;
}

static void setAllowOcc(void *r) {      // dynamic renderers are not occlusion-culled when this is false
    if (ic_rend_set_allow) ic_rend_set_allow(r, false);
    else if (mi_rend_allow) { bool f = false; void *a[1] = { &f }; inv(mi_rend_allow, r, a); }
}
static void forceVisible(bool full) {
    // Only enemy bodies: never "me" (the camera's own third-person body must stay hidden) and
    // never the first-person arms meshes (they float in the air if switched on).
    void *cam = d_cam_main(mi_cam_main);
    bool haveCam = false; V3 cp = { 0, 0, 0 };
    if (ic_cam_set_occ && cam && alive(cam)) ic_cam_set_occ(cam, false);   // keep Unity's baked occlusion culling off
    if (cam && alive(cam)) { void *ct = d_tr(cam, mi_tr); if (ct) { cp = d_pos(ct, mi_pos); haveCam = true; } }
    for (auto &p : g_pl) {
        void *po = il2_gc_get(p.obj);
        if (!alive(po)) continue;
        if (haveCam) {
            void *tr = d_tr(po, mi_tr);
            if (!tr) continue;
            V3 q = d_pos(tr, mi_pos);
            float dx = q.x - cp.x, dz = q.z - cp.z;
            if (dx * dx + dz * dz < kSelfRadius * kSelfRadius * 4) continue;      // me
        } else continue;
        if (p.body) {
            void *r = il2_gc_get(p.body);
            if (alive(r)) {
                bool t = true; void *a[1] = { &t };
                inv(mi_rend_enabled, r, a);
                { bool f = false; void *a2[1] = { &f }; inv(mi_rend_set_froff, r, a2); }
                setAllowOcc(r);
                if (full) inv(mi_smr_offscreen, r, a);
            }
        }
        if (!full) continue;
        for (uint32_t h : p.smr) { void *r2 = il2_gc_get(h); if (alive(r2)) setAllowOcc(r2); }
        for (uint32_t h : p.anim) {
            void *an = il2_gc_get(h);
            if (!alive(an)) continue;
            int mode = 0; void *a1[1] = { &mode };      // AnimatorCullingMode.AlwaysAnimate
            inv(mi_anim_cull, an, a1);
        }
    }
}

// ---- chams -----------------------------------------------------------------------------
struct Cham { uint32_t rend; uint32_t orig; };
static std::vector<Cham> g_chams;
static uint32_t g_chamMat = 0;
static const char *g_chamShaderUsed = nullptr;
static bool g_chamFailed = false;
static int g_chamMode = 2;          // 0 = shader has _ZTest, 1 = UI/Default via unity_GUIZTestMode, 2 = no x-ray
static uint32_t g_ztName = 0;

static void setMatInt(void *mat, const char *name, int v) {
    void *s = il2_string_new(name);
    void *args[2] = { s, &v };
    inv(mi_setint, mat, args);
}
static void updateChamColor() {
    if (!g_chamMat || !mi_set_color) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    UIColor *u = colorFor(g_set.color, 1);
    CGFloat r, g, b, a; [u getRed:&r green:&g blue:&b alpha:&a];
    Col c = { (float)r, (float)g, (float)b, 0.65f };
    void *args[1] = { &c };
    inv(mi_set_color, mat, args);
}
static bool matHasProp(void *mat, const char *name) {
    if (!mi_hasprop) return true;                       // cannot check: assume yes
    void *args[1] = { il2_string_new(name) };
    void *r = inv(mi_hasprop, mat, args);
    return r ? *(bool *)((char *)r + 16) : false;       // boxed bool
}
static int g_chamReapply = 0;
static bool ensureChamMaterial() {
    if (g_chamMat) return true;
    if (g_chamFailed || !mi_find_shader || !mi_mat_ctor || !k_material) { g_chamFailed = true; return false; }
    void *chosen = nullptr, *fallback = nullptr;
    const char *used = nullptr, *fallbackName = nullptr;
    int mode = 2;
    for (const char *nm : kChamShaders) {
        void *args[1] = { il2_string_new(nm) };
        void *shader = inv(mi_find_shader, nullptr, args);
        if (!shader) continue;
        void *mat = il2_object_new(k_material);
        if (!mat) continue;
        void *cargs[1] = { shader };
        inv(mi_mat_ctor, mat, cargs);
        int m = 2;
        if (!strcmp(nm, "Hidden/Internal-Colored")) m = matHasProp(mat, "_ZTest") ? 0 : 2;   // 0 = _ZTest property
        else if (!strcmp(nm, "GUI/Text Shader"))    m = 3;                                    // 3 = ZTest Always baked in
        else if (!strcmp(nm, "UI/Default"))         m = mi_setglobal ? 1 : 2;                 // 1 = via global
        if (m != 2) { chosen = mat; mode = m; used = nm; break; }
        if (!fallback) { fallback = mat; fallbackName = nm; }
    }
    if (!chosen) { chosen = fallback; used = fallbackName; mode = 2; }
    if (!chosen) { g_chamFailed = true; return false; }
    g_chamShaderUsed = used; g_chamMode = mode;
    g_chamMat = il2_gc_new(chosen, 0);
    if (g_chamMode == 0 && mi_setint) { setMatInt(chosen, "_ZTest", 8); setMatInt(chosen, "_ZWrite", 0); setMatInt(chosen, "_Cull", 0); }
    if (mi_set_queue) { int q = 3500; void *a[1] = { &q }; inv(mi_set_queue, chosen, a); }
    updateChamColor();
    NSLog(@"[SCESP] chams shader=%s mode=%d", used, mode);
    return true;
}
// UI/Default reads its ZTest from the global unity_GUIZTestMode; keep it on "Always" while chams are live
static void pumpChamZTest() {
    if (g_chamMode != 1 || !mi_setglobal || g_chams.empty()) return;
    if (!g_ztName) g_ztName = il2_gc_new(il2_string_new("unity_GUIZTestMode"), 0);
    void *nm = il2_gc_get(g_ztName);
    float v = 8.0f;
    void *args[2] = { nm, &v };
    inv(mi_setglobal, nullptr, args);
}
static void restoreCham(Cham &c) {
    void *r = il2_gc_get(c.rend), *orig = il2_gc_get(c.orig);
    if (r && alive(r) && orig) { void *a[1] = { orig }; inv(mi_set_smats, r, a); }
    il2_gc_free(c.rend); il2_gc_free(c.orig);
}
static void applyCham(void *rend) {
    void *orig = inv(mi_get_smats, rend, nullptr);
    if (!orig) return;
    uintptr_t n = *(uintptr_t *)((char *)orig + 24);
    if (n == 0 || n > 16) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    void *arr = il2_array_new(k_material, n);
    if (!arr) return;
    void **el = (void **)((char *)arr + 32);
    for (uintptr_t i = 0; i < n; i++) el[i] = mat;
    void *a[1] = { arr };
    if (inv(mi_set_smats, rend, a) == nullptr && false) return;
    g_chams.push_back({ il2_gc_new(rend, 0), il2_gc_new(orig, 0) });
}
// The game replaces sharedMaterials itself (hit flash, state change). Our entry would stay in g_chams
// while the cham is already gone -> check the live array and put our material back.
static void verifyChams() {
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    for (auto &c : g_chams) {
        void *r = il2_gc_get(c.rend);
        if (!r || !alive(r)) continue;
        void *cur = inv(mi_get_smats, r, nullptr);
        if (!cur) continue;
        uintptr_t n = *(uintptr_t *)((char *)cur + 24);
        if (n == 0 || n > 16) continue;
        void **el = (void **)((char *)cur + 32);
        bool ok = true;
        for (uintptr_t i = 0; i < n; i++) if (el[i] != mat) { ok = false; break; }
        if (ok) continue;
        void *arr = il2_array_new(k_material, n);
        if (!arr) continue;
        void **ne = (void **)((char *)arr + 32);
        for (uintptr_t i = 0; i < n; i++) ne[i] = mat;
        void *a[1] = { arr };
        inv(mi_set_smats, r, a);
        g_chamReapply++;
    }
}
// `want` = renderers that should carry chams right now (enemy SMRs); empty = restore everything
static void reconcileChams(const std::vector<void *> &want) {
    for (size_t i = 0; i < g_chams.size();) {
        void *r = il2_gc_get(g_chams[i].rend);
        bool keep = r && alive(r);
        if (keep) { keep = false; for (void *w : want) if (w == r) { keep = true; break; } }
        if (!keep) { restoreCham(g_chams[i]); g_chams.erase(g_chams.begin() + i); } else i++;
    }
    if (want.empty() || !mi_get_smats || !mi_set_smats || !ensureChamMaterial()) return;
    for (void *w : want) {
        bool has = false;
        for (auto &c : g_chams) if (il2_gc_get(c.rend) == w) { has = true; break; }
        if (!has) applyCham(w);
    }
}


// ---- chams via CommandBuffer -------------------------------------------------------------
// One CommandBuffer is attached to the main camera (AfterForwardAlpha) and records DrawRenderer(enemy, chamMaterial).
// The material has ZTest Always, so the enemy is painted over walls; DrawRenderer does not care whether the
// renderer was culled or occluded this frame, and the game cannot swap our material away (nothing is swapped).
static uint32_t g_cb = 0, g_cbCam = 0;
static std::vector<void *> g_cbList;
static bool g_cbFailed = false;
static const int kCamAfterForwardAlpha = 17;

static bool invOk(void *mi, void *obj, void **args) {
    if (!mi) return false;
    void *exc = nullptr;
    il2_invoke(mi, obj, args, &exc);
    return exc == nullptr;
}
static bool cbReady() { return !g_cbFailed && k_cmdbuf && mi_cb_ctor && mi_cb_clear && (mi_cb_draw2 || mi_cb_draw3) && mi_cam_addcb; }
static void cbDetach() {
    void *cb = g_cb ? il2_gc_get(g_cb) : nullptr;
    void *oc = g_cbCam ? il2_gc_get(g_cbCam) : nullptr;
    if (cb && oc && alive(oc) && mi_cam_rmcb) { int ev = kCamAfterForwardAlpha; void *a[2] = { &ev, cb }; invOk(mi_cam_rmcb, oc, a); }
    if (g_cbCam) { il2_gc_free(g_cbCam); g_cbCam = 0; }
}
static void cbClear() {
    void *cb = g_cb ? il2_gc_get(g_cb) : nullptr;
    if (cb) invOk(mi_cb_clear, cb, nullptr);
    g_cbList.clear();
}
// true = the buffer path is drawing the chams (caller must then NOT swap materials)
static bool cbUpdate(void *cam, const std::vector<void *> &want) {
    if (!cbReady() || !cam || !alive(cam)) return false;
    if (!ensureChamMaterial() || (g_chamMode != 0 && g_chamMode != 3)) return false;   // needs a shader with ZTest Always
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return false;
    if (!g_cb) {
        void *nb = il2_object_new(k_cmdbuf);
        if (!nb || !invOk(mi_cb_ctor, nb, nullptr)) { g_cbFailed = true; return false; }
        g_cb = il2_gc_new(nb, 0);
    }
    void *cb = il2_gc_get(g_cb);
    if (!cb) { g_cb = 0; return false; }
    void *cur = g_cbCam ? il2_gc_get(g_cbCam) : nullptr;
    bool relist = false;
    if (cur != cam || !alive(cur)) {                       // new camera (round change / scene load)
        if (g_cbCam) cbDetach();
        int ev = kCamAfterForwardAlpha; void *a[2] = { &ev, cb };
        if (!invOk(mi_cam_addcb, cam, a)) { g_cbFailed = true; return false; }
        g_cbCam = il2_gc_new(cam, 0);
        relist = true;
        NSLog(@"[SCESP] chams: CommandBuffer attached to camera %p", cam);
    }
    if (relist || want.size() != g_cbList.size() || !std::equal(want.begin(), want.end(), g_cbList.begin())) {
        cbClear();
        for (void *r : want) {
            if (!r || !alive(r)) continue;
            uintptr_t n = 1;
            if (mi_get_smats && mi_cb_draw3) {
                void *arr = inv(mi_get_smats, r, nullptr);
                if (arr) { n = *(uintptr_t *)((char *)arr + 24); if (n < 1 || n > 8) n = 1; }
            }
            for (uintptr_t i = 0; i < n; i++) {
                bool ok;
                if (mi_cb_draw3) { int sub = (int)i; void *a[3] = { r, mat, &sub }; ok = invOk(mi_cb_draw3, cb, a); }
                else             { void *a[2] = { r, mat };                           ok = invOk(mi_cb_draw2, cb, a); if (i == 0) {} }
                if (!ok) { g_cbFailed = true; cbClear(); return false; }
                if (!mi_cb_draw3) break;                    // the 2-arg overload only does submesh 0
            }
        }
        g_cbList = want;
    }
    return true;
}

// ---- class/method dump (for finding the fire path) ----------------------------------------
// Panel button "Dump fire path" (Aimbot tab; shows the text on screen, saves Documents/SCESP_dump.txt, also copies to clipboard): every class of the game image whose name looks shooting-related,
// with the methods that look relevant: signature + RVA (address minus image base).
static NSString *dumpFirePath() {
    void *game = findImage(kGameImage);
    if (!game) return @"game image not found";
    typedef size_t (*f_cnt)(void *);              typedef void *(*f_cls)(void *, size_t);
    typedef const char *(*f_nm)(void *);          typedef void *(*f_ret)(void *);
    f_cnt  imgCount = (f_cnt)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    f_cls  imgClass = (f_cls)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    f_nm   cName    = (f_nm)dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    f_nm   cNs      = (f_nm)dlsym(RTLD_DEFAULT, "il2cpp_class_get_namespace");
    f_ret  mRet     = (f_ret)dlsym(RTLD_DEFAULT, "il2cpp_method_get_return_type");
    if (!imgCount || !imgClass || !cName || !cNs || !mRet) return @"il2cpp class enumeration API missing";

    static const char *clsKeys[] = { "weapon", "gun", "shoot", "fire", "bullet", "projectile", "ballistic", "hitscan", "raycast", "aim", "recoil", "damage", "firearm", "shot" };
    static const char *mthKeys[] = { "fire", "shoot", "shot", "ray", "hit", "bullet", "aim", "spread", "recoil", "direction", "damage", "cast", "trace", "muzzle", "origin", "projectile", "attack" };
    auto lower = [](const char *in) { std::string o; for (; in && *in; in++) o += (char)tolower(*in); return o; };
    auto hit = [](const std::string &h, const char *const *keys, size_t n) { for (size_t i = 0; i < n; i++) if (h.find(keys[i]) != std::string::npos) return true; return false; };

    NSMutableString *out = [NSMutableString string];
    size_t total = imgCount(game);
    int classesOut = 0;
    for (size_t i = 0; i < total && classesOut < 80 && out.length < 60000; i++) {
        void *k = imgClass(game, i);
        if (!k) continue;
        std::string cn = lower(cName(k));
        if (!hit(cn, clsKeys, sizeof(clsKeys) / sizeof(clsKeys[0]))) continue;
        classesOut++;
        [out appendFormat:@"%s.%s\n", cNs(k), cName(k)];
        void *iter = nullptr, *m; int shown = 0;
        while ((m = il2_class_methods(k, &iter)) && shown < 40) {
            const char *mn = il2_method_name(m);
            if (!hit(lower(mn), mthKeys, sizeof(mthKeys) / sizeof(mthKeys[0]))) continue;
            shown++;
            NSMutableString *sig = [NSMutableString string];
            uint32_t pc = il2_method_pcount(m);
            for (uint32_t p = 0; p < pc; p++) { const char *tn = il2_type_name(il2_method_param(m, p)); [sig appendFormat:@"%s%s", p ? ", " : "", tn ? tn : "?"]; }
            const char *rn = il2_type_name(mRet(m));
            void *fp = direct(m); Dl_info di; long rva = 0;
            if (fp && dladdr(fp, &di)) rva = (long)((char *)fp - (char *)di.dli_fbase);
            [out appendFormat:@"  %s %s(%@)  rva=0x%lx\n", rn ? rn : "?", mn, sig, rva];
        }
    }
    return out.length ? out : @"nothing matched";
}

static bool unboxBool(void *b) { return b ? *(bool *)((char *)b + 16) : false; }
static int unboxInt(void *b) { return b ? *(int *)((char *)b + 16) : -1; }
// state of one enemy body renderer, as the engine sees it right now
static NSString *diagRenderer(void *r) {
    if (!r || !alive(r)) return @"diag: -";
    int en = mi_rend_get_enabled ? unboxBool(inv(mi_rend_get_enabled, r, nullptr)) : -1;
    int vis = ic_rend_vis ? (int)ic_rend_vis(r) : (mi_rend_isvis ? unboxBool(inv(mi_rend_isvis, r, nullptr)) : -1);
    int fo = mi_rend_get_froff ? unboxBool(inv(mi_rend_get_froff, r, nullptr)) : -1;
    int act = -1, layer = -1;
    void *go = mi_get_go ? inv(mi_get_go, r, nullptr) : nullptr;
    if (go) { act = mi_go_active ? unboxBool(inv(mi_go_active, go, nullptr)) : -1; layer = mi_go_layer ? unboxInt(inv(mi_go_layer, go, nullptr)) : -1; }
    void *cam = d_cam_main(mi_cam_main);
    int co = (cam && ic_cam_get_occ) ? (int)ic_cam_get_occ(cam) : ((cam && mi_cam_get_occ) ? unboxBool(inv(mi_cam_get_occ, cam, nullptr)) : -1);
    (void)fo;
    return [NSString stringWithFormat:@"e%d v%d a%d L%d o%d ic%d%d%d%d r%d", en, vis, act, layer, co,
            ic_cam_set_occ ? 1 : 0, ic_cam_get_occ ? 1 : 0, ic_rend_vis ? 1 : 0, ic_rend_set_allow ? 1 : 0, il2_resolve_icall ? 1 : 0];
}

// ---- UI --------------------------------------------------------------------------------
// ---- Neverlose-style UI kit ---------------------------------------------------------------
static UIColor *nlRGB(int r, int g, int b, CGFloat a = 1.0) { return [UIColor colorWithRed:r / 255.f green:g / 255.f blue:b / 255.f alpha:a]; }
static inline CGFloat nlMinX(CGRect r) { return r.origin.x; }
static inline CGFloat nlMaxX(CGRect r) { return r.origin.x + r.size.width; }
static inline CGFloat nlMaxY(CGRect r) { return r.origin.y + r.size.height; }
static inline CGFloat nlMidY(CGRect r) { return r.origin.y + r.size.height * 0.5; }   // no CoreGraphics link needed
#define NL_ACCENT nlRGB(61, 166, 255)
#define NL_WIN    nlRGB(10, 14, 22)
#define NL_SIDE   nlRGB(7, 10, 16)
#define NL_CARD   nlRGB(16, 23, 36)
#define NL_BORDER nlRGB(28, 38, 58)
#define NL_TEXT   nlRGB(201, 211, 227)
#define NL_DIM    nlRGB(107, 122, 147)
#define NL_OFF    nlRGB(30, 40, 58)

@interface NLToggle : UIControl
@property (nonatomic, assign) BOOL on;
- (instancetype)initWithFrame:(CGRect)f title:(NSString *)title;
@end
@implementation NLToggle {
    CALayer *_track, *_knob;
}
- (instancetype)initWithFrame:(CGRect)f title:(NSString *)title {
    if ((self = [super initWithFrame:f])) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, f.size.width - 56, f.size.height)];
        l.text = title; l.textColor = NL_TEXT; l.font = [UIFont systemFontOfSize:11]; l.userInteractionEnabled = NO;
        [self addSubview:l];
        _track = [CALayer layer]; _track.frame = CGRectMake(f.size.width - 40, (f.size.height - 16) / 2, 30, 16); _track.cornerRadius = 8;
        _knob = [CALayer layer]; _knob.bounds = CGRectMake(0, 0, 12, 12); _knob.cornerRadius = 6; _knob.backgroundColor = UIColor.whiteColor.CGColor;
        [self.layer addSublayer:_track]; [self.layer addSublayer:_knob];
        [self addTarget:self action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
        [self paint:NO];
    }
    return self;
}
- (void)flip { _on = !_on; [self paint:YES]; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)setOn:(BOOL)on { _on = on; [self paint:NO]; }
- (void)paint:(BOOL)anim {
    CGRect t = _track.frame;
    CGPoint c = CGPointMake(_on ? nlMaxX(t) - 8 : nlMinX(t) + 8, nlMidY(t));
    [CATransaction begin];
    [CATransaction setDisableActions:!anim];
    [CATransaction setAnimationDuration:0.14];
    _track.backgroundColor = (_on ? NL_ACCENT : NL_OFF).CGColor;
    _knob.position = c;
    [CATransaction commit];
}
@end

// Scroll view for the panel pages: lets a drag that starts on a toggle/button scroll the page
// (stock UIScrollView refuses to cancel touches inside UIControls, and the cards are full of them).
@interface NLScroll : UIScrollView
@end
@implementation NLScroll
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return YES; }
@end

// ---- colour picker: saturation/brightness square + hue strip ---------------------------------
@interface NLColorPicker : UIControl
- (CGFloat)hue; - (CGFloat)sat; - (CGFloat)val;
- (void)setHue:(CGFloat)h sat:(CGFloat)s val:(CGFloat)v;
@end
@implementation NLColorPicker {
    CALayer *_svBase, *_svKnob, *_hueKnob;
    CAGradientLayer *_svWhite, *_svBlack, *_hueBar;
    CGFloat _h, _s, _v;
    int _mode;                                   // 1 = dragging in the square, 2 = dragging on the hue strip
    __weak UIScrollView *_scroll;
}
- (CGFloat)hue { return _h; }
- (CGFloat)sat { return _s; }
- (CGFloat)val { return _v; }
static CALayer *nlKnob() {
    CALayer *k = [CALayer layer];
    k.bounds = CGRectMake(0, 0, 15, 15); k.cornerRadius = 7.5; k.borderWidth = 2; k.borderColor = UIColor.whiteColor.CGColor;
    k.shadowColor = UIColor.blackColor.CGColor; k.shadowOpacity = 0.6; k.shadowRadius = 2; k.shadowOffset = CGSizeMake(0, 0);
    return k;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    CGFloat w = f.size.width, svH = f.size.height - 24;
    _svBase = [CALayer layer]; _svBase.frame = CGRectMake(0, 0, w, svH); _svBase.cornerRadius = 6; _svBase.masksToBounds = YES;
    _svWhite = [CAGradientLayer layer]; _svWhite.frame = _svBase.bounds;
    _svWhite.colors = @[ (id)UIColor.whiteColor.CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor ];
    _svWhite.startPoint = CGPointMake(0, 0.5); _svWhite.endPoint = CGPointMake(1, 0.5);
    _svBlack = [CAGradientLayer layer]; _svBlack.frame = _svBase.bounds;
    _svBlack.colors = @[ (id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)UIColor.blackColor.CGColor ];
    _svBlack.startPoint = CGPointMake(0.5, 0); _svBlack.endPoint = CGPointMake(0.5, 1);
    [_svBase addSublayer:_svWhite]; [_svBase addSublayer:_svBlack]; [self.layer addSublayer:_svBase];
    _hueBar = [CAGradientLayer layer]; _hueBar.frame = CGRectMake(0, f.size.height - 16, w, 16);
    _hueBar.cornerRadius = 8; _hueBar.masksToBounds = YES;
    NSMutableArray *cols = [NSMutableArray array];
    for (int i = 0; i <= 6; i++) [cols addObject:(id)[UIColor colorWithHue:i / 6.0 saturation:1 brightness:1 alpha:1].CGColor];
    _hueBar.colors = cols; _hueBar.startPoint = CGPointMake(0, 0.5); _hueBar.endPoint = CGPointMake(1, 0.5);
    [self.layer addSublayer:_hueBar];
    _svKnob = nlKnob(); _hueKnob = nlKnob();
    [self.layer addSublayer:_svKnob]; [self.layer addSublayer:_hueKnob];
    _h = 0; _s = 0.85; _v = 1;
    [self refresh];
    return self;
}
- (void)refresh {
    CGFloat w = self.bounds.size.width, hh = self.bounds.size.height, svH = hh - 24;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _svBase.backgroundColor = [UIColor colorWithHue:_h saturation:1 brightness:1 alpha:1].CGColor;
    _svKnob.position = CGPointMake(_s * w, (1 - _v) * svH);
    _svKnob.backgroundColor = [UIColor colorWithHue:_h saturation:_s brightness:_v alpha:1].CGColor;
    _hueKnob.position = CGPointMake(fmax(8, fmin(w - 8, _h * w)), hh - 8);
    _hueKnob.backgroundColor = [UIColor colorWithHue:_h saturation:1 brightness:1 alpha:1].CGColor;
    [CATransaction commit];
}
- (void)setHue:(CGFloat)h sat:(CGFloat)s val:(CGFloat)v { _h = h; _s = s; _v = v; [self refresh]; }
- (void)applyPoint:(CGPoint)p {
    CGFloat w = self.bounds.size.width, svH = self.bounds.size.height - 24;
    if (_mode == 2) _h = fmax(0, fmin(1, p.x / w));
    else { _s = fmax(0, fmin(1, p.x / w)); _v = 1 - fmax(0, fmin(1, p.y / svH)); }
    [self refresh];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e {
    CGPoint p = [t locationInView:self];
    _mode = (p.y > self.bounds.size.height - 24 + 2) ? 2 : 1;
    for (UIView *v = self.superview; v; v = v.superview) if ([v isKindOfClass:UIScrollView.class]) { _scroll = (UIScrollView *)v; break; }
    _scroll.scrollEnabled = NO;                   // a vertical drag inside the square must not scroll the page
    [self applyPoint:p];
    return YES;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { [self applyPoint:[t locationInView:self]]; return YES; }
- (void)endTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { _scroll.scrollEnabled = YES; _scroll = nil; }
- (void)cancelTrackingWithEvent:(UIEvent *)e { _scroll.scrollEnabled = YES; _scroll = nil; }
@end

struct NLCard { __unsafe_unretained UIView *v; CGFloat y, w; };
static NLCard nlCard(UIView *parent, NSString *title, CGFloat x, CGFloat y, CGFloat w) {
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 30)];
    c.backgroundColor = NL_CARD; c.layer.cornerRadius = 8; c.layer.borderWidth = 1; c.layer.borderColor = NL_BORDER.CGColor;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, w - 20, 12)];
    t.attributedText = [[NSAttributedString alloc] initWithString:title.uppercaseString attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightBold], NSForegroundColorAttributeName: NL_DIM, NSKernAttributeName: @1.2 }];
    [c addSubview:t]; [parent addSubview:c];
    NLCard k; k.v = c; k.y = 28; k.w = w;
    return k;
}
static void nlEnd(NLCard &k) { CGRect f = k.v.frame; f.size.height = k.y + 6; k.v.frame = f; }
static void nlToggle(NLCard &k, NSString *title, int tag, BOOL on, id tgt, SEL sel) {
    NLToggle *t = [[NLToggle alloc] initWithFrame:CGRectMake(0, k.y, k.w, 24) title:title];
    t.tag = tag; t.on = on;
    [t addTarget:tgt action:sel forControlEvents:UIControlEventValueChanged];
    [k.v addSubview:t]; k.y += 24;
}
static UIImage *nlThumb() {
    static UIImage *img;
    if (!img) {
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(12, 12)];
        img = [r imageWithActions:^(UIGraphicsImageRendererContext *c) { [UIColor.whiteColor setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 12, 12)] fill]; }];
    }
    return img;
}
// returns the value label so the caller can keep it up to date
static UILabel *nlSlider(NLCard &k, NSString *title, int tag, float mn, float mx, float val, id tgt, SEL sel) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, k.y, k.w - 64, 14)];
    l.text = title; l.textColor = NL_TEXT; l.font = [UIFont systemFontOfSize:11];
    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(k.w - 56, k.y, 46, 14)];
    v.textColor = NL_ACCENT; v.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightSemibold]; v.textAlignment = NSTextAlignmentRight;
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(6, k.y + 14, k.w - 12, 20)];
    sl.minimumValue = mn; sl.maximumValue = mx; sl.value = val; sl.tag = tag;
    sl.minimumTrackTintColor = NL_ACCENT; sl.maximumTrackTintColor = NL_OFF;
    [sl setThumbImage:nlThumb() forState:UIControlStateNormal]; [sl setThumbImage:nlThumb() forState:UIControlStateHighlighted];
    [sl addTarget:tgt action:sel forControlEvents:UIControlEventValueChanged];
    [k.v addSubview:l]; [k.v addSubview:v]; [k.v addSubview:sl];
    k.y += 38;
    return v;
}
static UIButton *nlButton(NLCard &k, NSString *title, id tgt, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(10, k.y, k.w - 20, 24);
    b.backgroundColor = nlRGB(24, 34, 52); b.layer.cornerRadius = 6; b.layer.borderWidth = 1; b.layer.borderColor = NL_BORDER.CGColor;
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:NL_ACCENT forState:UIControlStateNormal];
    [b setTitleColor:NL_DIM forState:UIControlStateHighlighted];
    [b addTarget:tgt action:sel forControlEvents:UIControlEventTouchUpInside];
    [k.v addSubview:b]; k.y += 30;
    return b;
}
static UILabel *nlInfo(NLCard &k, CGFloat h, CGFloat font) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, k.y, k.w - 20, h)];
    l.numberOfLines = 0; l.textColor = NL_DIM; l.font = [UIFont monospacedSystemFontOfSize:font weight:UIFontWeightRegular];
    l.lineBreakMode = NSLineBreakByWordWrapping;
    [k.v addSubview:l]; k.y += h + 4;
    return l;
}
static void nlSwatches(NLCard &k, int sel, id tgt, SEL act, NSMutableArray *out) {
    CGFloat step = (k.w - 20) / 7.0;
    for (int i = 0; i < 7; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(10 + i * step + (step - 20) / 2, k.y, 20, 20);
        b.backgroundColor = colorFor(i, 1); b.layer.cornerRadius = 10; b.tag = i;
        b.layer.borderWidth = (i == sel) ? 2 : 0; b.layer.borderColor = UIColor.whiteColor.CGColor;
        [b addTarget:tgt action:act forControlEvents:UIControlEventTouchUpInside];
        [k.v addSubview:b]; [out addObject:b];
    }
    k.y += 28;
}

// ---- T-side agent: procedural 3D model (SceneKit). Every aim region is its own node named "aim_<AimPart>". ----
static SCNNode *aimMesh(SCNGeometry *g, UIColor *c, int part, float x, float y, float z) {
    SCNMaterial *m = [SCNMaterial material];
    m.diffuse.contents = c; m.specular.contents = [UIColor colorWithWhite:0.25 alpha:1]; m.lightingModelName = SCNLightingModelBlinn;
    g.materials = @[m];
    SCNNode *n = [SCNNode nodeWithGeometry:g];
    n.position = SCNVector3Make(x, y, z);
    if (part >= 0) n.name = [NSString stringWithFormat:@"aim_%d", part];
    return n;
}
static UIColor *aimRGB(int r, int g, int b) { return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1]; }
static SCNNode *buildAgentModel() {
    SCNNode *root = [SCNNode node];
    UIColor *black = aimRGB(28, 30, 38), *red = aimRGB(196, 44, 38), *vest = aimRGB(86, 92, 106), *pants = aimRGB(48, 54, 66),
            *skin = aimRGB(214, 140, 92), *wrap = aimRGB(226, 226, 230), *gunc = aimRGB(34, 36, 40);
    // head: balaclava + red stripes + eye slit
    SCNNode *head = aimMesh([SCNSphere sphereWithRadius:0.118], black, kAimHead, 0, 1.72, 0);
    head.scale = SCNVector3Make(0.95, 1.12, 1.0);
    for (int s = -1; s <= 1; s += 2) {
        SCNNode *st = aimMesh([SCNBox boxWithWidth:0.014 height:0.2 length:0.012 chamferRadius:0], red, -1, s * 0.05, 0.0, 0.108);
        st.name = [NSString stringWithFormat:@"aim_%d", kAimHead]; [head addChildNode:st];
    }
    SCNNode *slit = aimMesh([SCNBox boxWithWidth:0.115 height:0.032 length:0.01 chamferRadius:0], skin, -1, 0, 0.02, 0.112);
    slit.name = [NSString stringWithFormat:@"aim_%d", kAimHead]; [head addChildNode:slit];
    [root addChildNode:head];
    // neck (red hood collar)
    [root addChildNode:aimMesh([SCNCylinder cylinderWithRadius:0.075 height:0.12], red, kAimNeck, 0, 1.585, 0)];
    // torso
    [root addChildNode:aimMesh([SCNBox boxWithWidth:0.42 height:0.30 length:0.25 chamferRadius:0.03], vest, kAimChest, 0, 1.40, 0)];
    [root addChildNode:aimMesh([SCNBox boxWithWidth:0.36 height:0.22 length:0.22 chamferRadius:0.02], red, kAimStomach, 0, 1.15, 0)];
    [root addChildNode:aimMesh([SCNBox boxWithWidth:0.38 height:0.20 length:0.23 chamferRadius:0.02], pants, kAimPelvis, 0, 0.94, 0)];
    // arms: upper arm hangs, forearm points forward to the rifle
    for (int s = -1; s <= 1; s += 2) {
        SCNNode *up = aimMesh([SCNCapsule capsuleWithCapRadius:0.058 height:0.40], skin, kAimArm, s * 0.285, 1.33, 0.02);
        up.eulerAngles = SCNVector3Make(0, 0, -s * 0.10); [root addChildNode:up];
        SCNNode *fore = aimMesh([SCNCapsule capsuleWithCapRadius:0.05 height:0.36], skin, kAimArm, s * 0.21, 1.14, 0.17);
        fore.eulerAngles = SCNVector3Make(1.25, 0, 0); [root addChildNode:fore];
        SCNNode *w = aimMesh([SCNCylinder cylinderWithRadius:0.056 height:0.09], wrap, kAimArm, s * 0.21, 1.10, 0.31);
        w.eulerAngles = SCNVector3Make(1.25, 0, 0); [root addChildNode:w];
        // red shirt sleeve cap on the shoulder
        [root addChildNode:aimMesh([SCNSphere sphereWithRadius:0.075], red, kAimArm, s * 0.265, 1.50, 0.0)];
    }
    // legs + feet
    for (int s = -1; s <= 1; s += 2) {
        [root addChildNode:aimMesh([SCNCapsule capsuleWithCapRadius:0.085 height:0.84], pants, kAimLeg, s * 0.105, 0.47, 0)];
        [root addChildNode:aimMesh([SCNBox boxWithWidth:0.13 height:0.08 length:0.30 chamferRadius:0.03], black, kAimFoot, s * 0.105, 0.04, 0.06)];
    }
    // rifle (decor, no aim part: hit test ignores it)
    [root addChildNode:aimMesh([SCNBox boxWithWidth:0.06 height:0.09 length:0.95 chamferRadius:0.01], gunc, -1, 0.04, 1.12, 0.36)];
    [root addChildNode:aimMesh([SCNBox boxWithWidth:0.05 height:0.17 length:0.07 chamferRadius:0.005], gunc, -1, 0.04, 0.99, 0.30)];
    return root;
}

@interface SCESPDriver : NSObject
- (void)tick;
@end

@implementation SCESPDriver {
    UIView *_overlay;
    CAShapeLayer *_boxes, *_skel;
    CAShapeLayer *_hpBack, *_hpG, *_hpY, *_hpR, *_hdot, *_arm, *_armFlag;
    NSMutableArray *_barLabels;
    NSMutableArray *_wepLabels;
    UIButton *_btn, *_hpBtn;
    UIView *_panel;
    UILabel *_status;
    UITextView *_dumpView; UIButton *_dumpClose;
    UILabel *_lwLabel, *_hdLabel, *_fovLabel, *_spdLabel, *_aimInfo, *_tabTitle;
    UILabel *_bhStepLabel, *_bhMaxLabel, *_bhRstLabel, *_bhopInfo;
    NSMutableArray *_vmLabels;
    UILabel *_vmInfo, *_stInfo, *_stAspLabel;
    CAShapeLayer *_fovRing;
    NSMutableArray *_pages, *_tabs, *_swatches, *_dmgLabels;
    NLColorPicker *_picker;
    UILabel *_hexLabel;
    NSMutableArray *_aimPartButtons, *_aimChipButtons;
    SCNView *_agentView; SCNNode *_agentRoot;
    UILabel *_aimPartInfo;
    int _frame, _vfy;
    void *_diagR;
    double _lastTick, _lastScan;
}

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
}

- (void)addSwitch:(NSString *)title col:(int)col row:(int)row tag:(int)tag on:(BOOL)on {
    CGFloat cx = col ? 170 : 10, y = 30 + row * 24;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(cx, y, 96, 26)];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7;
    UISwitch *s = [[UISwitch alloc] init];
    s.transform = (CGAffineTransform){ 0.68, 0, 0, 0.68, 0, 0 };
    s.center = CGPointMake(cx + 96 + 20, y + 13);
    s.tag = tag; s.on = on;
    [s addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:l]; [_panel addSubview:s];
}

- (void)buildPanel {
    const CGFloat W = 470, H = 300, SB = 88;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(8, 72, W, H)];
    _panel.backgroundColor = [NL_WIN colorWithAlphaComponent:0.97];
    _panel.layer.cornerRadius = 12; _panel.layer.borderWidth = 1; _panel.layer.borderColor = NL_BORDER.CGColor;
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    _pages = [NSMutableArray array]; _tabs = [NSMutableArray array]; _swatches = [NSMutableArray array];

    // sidebar
    UIView *side = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SB, H)];
    side.backgroundColor = NL_SIDE;
    [_panel addSubview:side];
    UILabel *logo = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, SB - 14, 20)];
    logo.attributedText = [[NSAttributedString alloc] initWithString:@"SCESP" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy], NSForegroundColorAttributeName: NL_ACCENT, NSKernAttributeName: @1.5 }];
    [side addSubview:logo];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(14, 32, SB - 14, 12)];
    sub.text = @"offline bots"; sub.textColor = NL_DIM; sub.font = [UIFont systemFontOfSize:9];
    [side addSubview:sub];
    UIView *dragA = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SB, 52)];
    [dragA addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)]];
    [side addSubview:dragA];
    UIView *vline = [[UIView alloc] initWithFrame:CGRectMake(SB, 0, 1, H)]; vline.backgroundColor = NL_BORDER; [_panel addSubview:vline];

    // top bar (drag handle + close)
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(SB + 1, 0, W - SB - 1, 32)];
    [top addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)]];
    [_panel addSubview:top];
    _tabTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 200, 32)];
    _tabTitle.textColor = NL_TEXT; _tabTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [top addSubview:_tabTitle];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(W - SB - 150, 0, 110, 32)];
    hint.text = @"drag to move"; hint.textColor = NL_DIM; hint.font = [UIFont systemFontOfSize:9]; hint.textAlignment = NSTextAlignmentRight;
    [top addSubview:hint];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.frame = CGRectMake(W - SB - 34, 4, 24, 24);
    [x setTitle:@"\u2715" forState:UIControlStateNormal]; [x setTitleColor:NL_DIM forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:13];
    [x addTarget:self action:@selector(plateTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:x];
    UIView *hline = [[UIView alloc] initWithFrame:CGRectMake(SB + 1, 32, W - SB - 1, 1)]; hline.backgroundColor = NL_BORDER; [_panel addSubview:hline];

    // tabs + pages
    const CGFloat PX = SB + 9, PY = 40, PW = W - SB - 17, PH = H - PY - 6, CW = (PW - 8) / 2;
    NSArray *names = @[@"Aimbot", @"Visuals", @"Misc"], *icons = @[@"scope", @"eye", @"slider.horizontal.3"];
    for (int i = 0; i < 3; i++) {
        UIButton *tb = [UIButton buttonWithType:UIButtonTypeCustom];
        tb.frame = CGRectMake(0, 62 + i * 34, SB, 32); tb.tag = i;
        tb.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        tb.contentEdgeInsets = UIEdgeInsetsMake(0, 36, 0, 0);
#pragma clang diagnostic pop
        tb.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [tb setTitle:names[i] forState:UIControlStateNormal];
        UIImageView *ic = [[UIImageView alloc] initWithFrame:CGRectMake(14, 8, 16, 16)];
        ic.image = [UIImage systemImageNamed:icons[i]]; ic.contentMode = UIViewContentModeScaleAspectFit; ic.tag = 901; ic.userInteractionEnabled = NO;
        [tb addSubview:ic];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 6, 2, 20)]; bar.backgroundColor = NL_ACCENT; bar.tag = 900; [tb addSubview:bar];
        [tb addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [side addSubview:tb]; [_tabs addObject:tb];

        UIScrollView *pg = [[NLScroll alloc] initWithFrame:CGRectMake(PX, PY, PW, PH)];
        pg.showsVerticalScrollIndicator = YES; pg.alwaysBounceVertical = YES; pg.delaysContentTouches = NO;
        pg.canCancelContentTouches = YES; pg.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [_panel addSubview:pg]; [_pages addObject:pg];
    }

    // --- Aimbot ---
    {
        UIScrollView *pg = _pages[0];
        NLCard a = nlCard(pg, @"Aim lock", 0, 0, CW);
        nlToggle(a, @"Enabled", 8, g_set.aim, self, @selector(swChanged:));
        nlToggle(a, @"Draw FOV", 15, g_set.drawFov, self, @selector(swChanged:));
        nlToggle(a, @"Silent aim (bots)", 41, g_set.silent, self, @selector(swChanged:));
        _fovLabel = nlSlider(a, @"FOV", 13, 5, 90, g_set.fov, self, @selector(slChanged:));
        _spdLabel = nlSlider(a, @"Speed", 14, 4, 40, g_set.aimSpeed, self, @selector(slChanged:));
        nlEnd(a);
        NLCard b = nlCard(pg, @"Look fields", CW + 8, 0, CW);
        nlButton(b, @"Learn look fields", self, @selector(learnTapped));
        nlButton(b, @"Use dump fields", self, @selector(dumpFieldsTapped));
        nlButton(b, @"Dump fire path", self, @selector(dumpTapped));
        _aimInfo = nlInfo(b, 44, 9);
        nlEnd(b);

        // T-side agent preview: 3D model, tap a body part to choose the aim region, drag or use the arrows to rotate.
        CGFloat previewY = fmax(nlMaxY(a.v.frame), nlMaxY(b.v.frame)) + 8;
        NLCard preview = nlCard(pg, @"T-SIDE / TARGET POINT", 0, previewY, PW);
        const CGFloat VW = 190, VH = 250, VX = 10, VY = 28;
        _agentView = [[SCNView alloc] initWithFrame:CGRectMake(VX, VY, VW, VH)];
        _agentView.layer.cornerRadius = 8; _agentView.clipsToBounds = YES;
        _agentView.layer.borderWidth = 1; _agentView.layer.borderColor = NL_BORDER.CGColor;
        _agentView.antialiasingMode = SCNAntialiasingModeMultisampling4X;
        _agentView.backgroundColor = aimRGB(30, 24, 36);
        SCNScene *scene = [SCNScene scene];
        _agentRoot = buildAgentModel();
        _agentRoot.eulerAngles = SCNVector3Make(0, -0.55, 0);
        [scene.rootNode addChildNode:_agentRoot];
        SCNNode *cam = [SCNNode node]; cam.camera = [SCNCamera camera]; cam.camera.fieldOfView = 32;
        cam.position = SCNVector3Make(0, 0.98, 3.35); [scene.rootNode addChildNode:cam];
        SCNNode *amb = [SCNNode node]; amb.light = [SCNLight light]; amb.light.type = SCNLightTypeAmbient;
        amb.light.color = [UIColor colorWithWhite:0.42 alpha:1]; [scene.rootNode addChildNode:amb];
        SCNNode *key = [SCNNode node]; key.light = [SCNLight light]; key.light.type = SCNLightTypeDirectional;
        key.light.color = [UIColor colorWithWhite:0.95 alpha:1]; key.eulerAngles = SCNVector3Make(-0.5, 0.6, 0); [scene.rootNode addChildNode:key];
        SCNNode *rim = [SCNNode node]; rim.light = [SCNLight light]; rim.light.type = SCNLightTypeDirectional;
        rim.light.color = aimRGB(180, 60, 60); rim.eulerAngles = SCNVector3Make(-0.2, -2.4, 0); [scene.rootNode addChildNode:rim];
        _agentView.scene = scene; _agentView.pointOfView = cam;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(agentTapped:)];
        [_agentView addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(agentPanned:)];
        [_agentView addGestureRecognizer:pan];
        [preview.v addSubview:_agentView];
        for (int dir = -1; dir <= 1; dir += 2) {
            UIButton *r = [UIButton buttonWithType:UIButtonTypeCustom];
            r.frame = CGRectMake(dir < 0 ? 6 : VW - 32, VH - 30, 26, 24); r.tag = dir;
            r.backgroundColor = [NL_SIDE colorWithAlphaComponent:0.7]; r.layer.cornerRadius = 6;
            r.layer.borderWidth = 1; r.layer.borderColor = NL_BORDER.CGColor;
            [r setTitle:(dir < 0 ? @"\u2039" : @"\u203A") forState:UIControlStateNormal];
            [r setTitleColor:NL_ACCENT forState:UIControlStateNormal];
            r.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
            [r addTarget:self action:@selector(agentRotateTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_agentView addSubview:r];
        }
        _aimPartButtons = [NSMutableArray array];
        _aimChipButtons = [NSMutableArray array];
        const int order[kAimPartCount] = { kAimHead, kAimNeck, kAimChest, kAimStomach, kAimPelvis, kAimArm, kAimLeg, kAimFoot };
        const CGFloat chipX = VX + VW + 12, chipW = PW - chipX - 10, chipH = 25, chipGap = 6;
        for (int i = 0; i < kAimPartCount; i++) {
            UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
            chip.frame = CGRectMake(chipX, VY + i * (chipH + chipGap), chipW, chipH);
            chip.tag = order[i]; chip.layer.cornerRadius = 6; chip.layer.borderWidth = 1;
            chip.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
            [chip setTitle:aimPartTitle(order[i]).uppercaseString forState:UIControlStateNormal];
            [chip addTarget:self action:@selector(aimPartTapped:) forControlEvents:UIControlEventTouchUpInside];
            [preview.v addSubview:chip]; [_aimChipButtons addObject:chip];
        }
        _aimPartInfo = [[UILabel alloc] initWithFrame:CGRectMake(12, VY + VH + 8, PW - 24, 14)];
        _aimPartInfo.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightSemibold];
        _aimPartInfo.textColor = NL_ACCENT;
        [preview.v addSubview:_aimPartInfo];
        preview.y = VY + VH + 30; nlEnd(preview);
        [self refreshAimPartPreview];
        pg.contentSize = CGSizeMake(PW, nlMaxY(preview.v.frame) + 8);
    }
    // --- Visuals ---
    {
        UIScrollView *pg = _pages[1];
        NLCard a = nlCard(pg, @"Players", 0, 0, CW);
        nlToggle(a, @"ESP", 0, g_set.on, self, @selector(swChanged:));
        nlToggle(a, @"Box", 1, g_set.box, self, @selector(swChanged:));
        nlToggle(a, @"Box fill", 4, g_set.fill, self, @selector(swChanged:));
        nlToggle(a, @"Skeleton", 2, g_set.skel, self, @selector(swChanged:));
        nlToggle(a, @"Chams", 3, g_set.chams, self, @selector(swChanged:));
        nlToggle(a, @"Head dot", 12, g_set.hdot, self, @selector(swChanged:));
        nlToggle(a, @"Health bar", 9, g_set.hp, self, @selector(swChanged:));
        nlToggle(a, @"Armor bar", 18, g_set.armor, self, @selector(swChanged:));
        nlToggle(a, @"Weapon name", 24, g_set.wep, self, @selector(swChanged:));
        nlToggle(a, @"Damage numbers", 16, g_set.dmg, self, @selector(swChanged:));
        nlToggle(a, @"My damage only", 17, g_set.dmgMine, self, @selector(swChanged:));
        nlToggle(a, @"Teammates", 5, g_set.team, self, @selector(swChanged:));
        nlEnd(a);
        NLCard b = nlCard(pg, @"Style", CW + 8, 0, CW);
        {
            NLColorPicker *cp = [[NLColorPicker alloc] initWithFrame:CGRectMake(10, b.y, b.w - 20, 112)];
            [cp setHue:g_set.ch sat:g_set.cs val:g_set.cv];
            [cp addTarget:self action:@selector(pickChanged:) forControlEvents:UIControlEventValueChanged];
            [cp addTarget:self action:@selector(pickDone) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [b.v addSubview:cp]; _picker = cp; b.y += 118;
            _hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, b.y, b.w - 20, 14)];
            _hexLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold]; _hexLabel.textColor = NL_ACCENT;
            _hexLabel.textAlignment = NSTextAlignmentCenter;
            [b.v addSubview:_hexLabel]; b.y += 18;
            [self updateHex];
        }
        _lwLabel = nlSlider(b, @"Line width", 10, 0.5, 4, g_set.lw, self, @selector(slChanged:));
        _hdLabel = nlSlider(b, @"Box height", 11, 1.4, 2.2, g_set.head, self, @selector(slChanged:));
        nlEnd(b);
        NLCard c = nlCard(pg, @"Health", CW + 8, nlMaxY(b.v.frame) + 8, CW);
        _hpBtn = nlButton(c, @"Learn health", self, @selector(hpLearnTapped));
        nlEnd(c);
        pg.contentSize = CGSizeMake(PW, fmax(nlMaxY(a.v.frame), nlMaxY(c.v.frame)) + 8);
    }
    // --- Misc ---
    {
        UIScrollView *pg = _pages[2];
        NLCard a = nlCard(pg, @"Performance", 0, 0, CW);
        nlToggle(a, @"Low CPU", 6, g_set.lowcpu, self, @selector(swChanged:));
        nlToggle(a, @"No occlusion", 7, g_set.noocc, self, @selector(swChanged:));
        nlToggle(a, @"No spread (bots)", 40, g_set.nospread, self, @selector(swChanged:));
        nlEnd(a);
        NLCard mv = nlCard(pg, @"Movement", CW + 8, 0, CW);
        nlToggle(mv, @"Bunny hop", 19, g_set.bhop, self, @selector(swChanged:));
        nlToggle(mv, @"Custom values", 20, g_set.bhopCustom, self, @selector(swChanged:));
        _bhStepLabel = nlSlider(mv, @"Speed step", 21, 0.25, 4, g_set.bhopStep, self, @selector(slChanged:));
        _bhMaxLabel  = nlSlider(mv, @"Max speed", 22, 0.25, 4, g_set.bhopMax, self, @selector(slChanged:));
        _bhRstLabel  = nlSlider(mv, @"Reset time", 23, 0.1, 4, g_set.bhopReset, self, @selector(slChanged:));
        _bhopInfo = nlInfo(mv, 34, 8);
        nlEnd(mv);
        // --- Viewmodel (custom hands) ---
        NLCard vm = nlCard(pg, @"Viewmodel", 0, nlMaxY(a.v.frame) + 8, CW);
        nlToggle(vm, @"Custom hands", 25, g_set.vm, self, @selector(swChanged:));
        _vmLabels = [NSMutableArray array];
        static const struct { const char *t; float mn, mx; } kVm[9] = {
            { "Pos X", -0.5f, 0.5f }, { "Pos Y", -0.5f, 0.5f }, { "Pos Z", -0.5f, 0.5f },
            { "Rot X", -45, 45 }, { "Rot Y", -45, 45 }, { "Rot Z", -45, 45 },
            { "Extra FOV", -20, 40 }, { "Hands type", -1, 6 }, { "FOV type", -1, 6 } };
        for (int i = 0; i < 9; i++)
            [_vmLabels addObject:nlSlider(vm, [NSString stringWithUTF8String:kVm[i].t], 30 + i, kVm[i].mn, kVm[i].mx, g_set.vmv[i], self, @selector(slChanged:))];
        _vmInfo = nlInfo(vm, 64, 8);
        nlEnd(vm);
        // --- Stretch ---
        NLCard sr = nlCard(pg, @"Stretch", CW + 8, nlMaxY(mv.v.frame) + 8, CW);
        nlToggle(sr, @"Stretched res", 26, g_set.stretch, self, @selector(swChanged:));
        _stAspLabel = nlSlider(sr, @"Aspect (w/h)", 39, 1.0, 2.2, g_set.stretchAspect, self, @selector(slChanged:));
        _stInfo = nlInfo(sr, 34, 8);
        nlEnd(sr);
        NLCard st = nlCard(pg, @"Status", 0, fmax(fmax(nlMaxY(vm.v.frame), nlMaxY(sr.v.frame)), fmax(nlMaxY(a.v.frame), nlMaxY(mv.v.frame))) + 8, PW);
        _status = nlInfo(st, 84, 8.5);
        _status.textColor = nlRGB(150, 165, 190);
        nlEnd(st);
        pg.contentSize = CGSizeMake(PW, nlMaxY(st.v.frame) + 8);
    }
    [self selectTab:0];
    [self refreshLabels];
}

- (void)selectTab:(NSInteger)i {
    NSArray *names = @[@"Aimbot", @"Visuals", @"Misc"];
    for (NSInteger k = 0; k < (NSInteger)_pages.count; k++) {
        BOOL on = (k == i);
        ((UIScrollView *)_pages[k]).hidden = !on;
        UIButton *b = _tabs[k];
        b.backgroundColor = on ? [NL_ACCENT colorWithAlphaComponent:0.12] : UIColor.clearColor;
        [b setTitleColor:on ? NL_ACCENT : NL_DIM forState:UIControlStateNormal];
        [b viewWithTag:900].hidden = !on;
        ((UIImageView *)[b viewWithTag:901]).tintColor = on ? NL_ACCENT : NL_DIM;
    }
    _tabTitle.text = names[i];
}
- (void)tabTapped:(UIButton *)b { [self selectTab:b.tag]; }
- (void)refreshAimPartPreview {
    // 3D: selected region glows, everything else is plain
    [_agentRoot enumerateHierarchyUsingBlock:^(SCNNode *n, BOOL *stop) {
        if (![n.name hasPrefix:@"aim_"] || !n.geometry) return;
        BOOL sel = [[n.name substringFromIndex:4] intValue] == g_selectedAimPart;
        n.geometry.firstMaterial.emission.contents = sel ? [NL_ACCENT colorWithAlphaComponent:1] : UIColor.blackColor;
        n.geometry.firstMaterial.emission.intensity = sel ? 0.75 : 0;
    }];
    for (UIButton *chip in _aimChipButtons) {
        BOOL selected = chip.tag == g_selectedAimPart;
        chip.backgroundColor = selected ? [NL_ACCENT colorWithAlphaComponent:0.22] : [NL_SIDE colorWithAlphaComponent:0.72];
        chip.layer.borderColor = (selected ? NL_ACCENT : NL_BORDER).CGColor;
        [chip setTitleColor:(selected ? NL_ACCENT : NL_TEXT) forState:UIControlStateNormal];
    }
    _aimPartInfo.text = [NSString stringWithFormat:@"AIM TARGET: %@   \u2022   TAP A BODY PART", aimPartTitle(g_selectedAimPart).uppercaseString];
}
- (void)agentTapped:(UITapGestureRecognizer *)g {
    NSArray<SCNHitTestResult *> *hits = [_agentView hitTest:[g locationInView:_agentView] options:@{ SCNHitTestBackFaceCullingKey: @YES }];
    for (SCNHitTestResult *h in hits) {
        for (SCNNode *n = h.node; n; n = n.parentNode) {
            if (![n.name hasPrefix:@"aim_"]) continue;
            int part = [[n.name substringFromIndex:4] intValue];
            if (part < 0 || part >= kAimPartCount) return;
            g_selectedAimPart = part; saveSettings(); [self refreshAimPartPreview];
            return;
        }
    }
}
- (void)agentPanned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_agentView];
    SCNVector3 e = _agentRoot.eulerAngles; e.y += t.x * 0.014f; _agentRoot.eulerAngles = e;
    [g setTranslation:CGPointMake(0, 0) inView:_agentView];
}
- (void)agentRotateTapped:(UIButton *)b {
    [SCNTransaction begin]; [SCNTransaction setAnimationDuration:0.25];
    SCNVector3 e = _agentRoot.eulerAngles; e.y += (float)b.tag * 0.6f; _agentRoot.eulerAngles = e;
    [SCNTransaction commit];
}
- (void)aimPartTapped:(UIButton *)b {
    if (b.tag < 0 || b.tag >= kAimPartCount) return;
    g_selectedAimPart = (int)b.tag;
    saveSettings();
    [self refreshAimPartPreview];
}
- (void)updateHex {
    CGFloat r = 0, g = 0, bl = 0, a = 0;
    [colorFor(g_set.color, 1) getRed:&r green:&g blue:&bl alpha:&a];
    _hexLabel.text = [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(r * 255), (int)lround(g * 255), (int)lround(bl * 255)];
}
- (void)pickChanged:(NLColorPicker *)p {
    g_set.ch = [p hue]; g_set.cs = [p sat]; g_set.cv = [p val]; g_set.color = -1;      // custom colour
    for (UIButton *sw in _swatches) sw.layer.borderWidth = 0;
    g_dirty = true; [self updateHex];
}
- (void)pickDone { saveSettings(); }
- (void)colorTapped:(UIButton *)b {
    g_set.color = (int)b.tag; g_dirty = true;
    {   // keep the picker in sync with the preset
        CGFloat h = 0, sa = 0, v = 0, al = 0;
        if ([colorFor(g_set.color, 1) getHue:&h saturation:&sa brightness:&v alpha:&al]) { g_set.ch = h; g_set.cs = sa; g_set.cv = v; [_picker setHue:h sat:sa val:v]; }
        [self updateHex];
    }
    saveSettings();
    for (UIButton *sw in _swatches) sw.layer.borderWidth = (sw.tag == b.tag) ? 2 : 0;
}

- (void)panMoved:(UIPanGestureRecognizer *)g {
    UIView *sv = _panel.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    CGPoint c = CGPointMake(_panel.center.x + t.x, _panel.center.y + t.y);
    CGSize hs = CGSizeMake(_panel.bounds.size.width / 2, _panel.bounds.size.height / 2);
    if (c.x < hs.width * 0.3) c.x = hs.width * 0.3;
    if (c.y < hs.height * 0.3) c.y = hs.height * 0.3;
    if (c.x > sv.bounds.size.width - hs.width * 0.3) c.x = sv.bounds.size.width - hs.width * 0.3;
    if (c.y > sv.bounds.size.height - hs.height * 0.3) c.y = sv.bounds.size.height - hs.height * 0.3;
    _panel.center = c;
    [g setTranslation:CGPointMake(0, 0) inView:sv];
}

- (void)refreshLabels {
    _lwLabel.text = [NSString stringWithFormat:@"%.1f", g_set.lw];
    _hdLabel.text = [NSString stringWithFormat:@"%.2f m", g_set.head];
    _fovLabel.text = [NSString stringWithFormat:@"%.0f\u00B0", g_set.fov];
    _spdLabel.text = [NSString stringWithFormat:@"%.0f", g_set.aimSpeed];
    _bhStepLabel.text = [NSString stringWithFormat:@"x%.2f", g_set.bhopStep];
    _bhMaxLabel.text  = [NSString stringWithFormat:@"x%.2f", g_set.bhopMax];
    _bhRstLabel.text  = [NSString stringWithFormat:@"x%.2f", g_set.bhopReset];
    for (int i = 0; i < 9 && i < (int)_vmLabels.count; i++) {
        float v = g_set.vmv[i];
        NSString *t = i < 3 ? [NSString stringWithFormat:@"%.3f", v]
                    : i < 6 ? [NSString stringWithFormat:@"%.0f\u00B0", v]
                    : i == 6 ? [NSString stringWithFormat:@"%+.0f\u00B0", v]
                    : (lroundf(v) < 0 ? @"keep" : [NSString stringWithFormat:@"%ld", lroundf(v)]);
        ((UILabel *)_vmLabels[i]).text = t;
    }
    _stAspLabel.text = [NSString stringWithFormat:@"%.2f", g_set.stretchAspect];
}

- (void)swChanged:(NLToggle *)s {
    switch (s.tag) {
        case 0: g_set.on = s.on; break;
        case 1: g_set.box = s.on; break;
        case 2: g_set.skel = s.on; break;
        case 3: g_set.chams = s.on; break;
        case 4: g_set.fill = s.on; break;
        case 5: g_set.team = s.on; break;
        case 6: g_set.lowcpu = s.on; break;
        case 7: g_set.noocc = s.on; break;
        case 8: g_set.aim = s.on; break;
        case 9: g_set.hp = s.on; break;
        case 12: g_set.hdot = s.on; break;
        case 15: g_set.drawFov = s.on; break;
        case 16: g_set.dmg = s.on; if (!s.on) g_pops.clear(); break;
        case 17: g_set.dmgMine = s.on; break;
        case 18: g_set.armor = s.on; break;
        case 24: g_set.wep = s.on; break;
        case 19: g_set.bhop = s.on; g_bhopForce = true; g_bhopParamsDirty = true; break;
        case 20: g_set.bhopCustom = s.on; g_bhopParamsDirty = true; break;
        case 25: g_set.vm = s.on; g_vmForce = true; break;
        case 26: g_set.stretch = s.on; g_stTries = 0; break;
        case 40: g_set.nospread = s.on; break;
        case 41: g_set.silent = s.on; break;
    }
    g_dirty = true; saveSettings();
}
- (void)segChanged:(UISegmentedControl *)s { g_set.color = (int)s.selectedSegmentIndex; g_dirty = true; saveSettings(); }
- (void)slChanged:(UISlider *)s {
    if (s.tag == 10) g_set.lw = s.value; else if (s.tag == 13) g_set.fov = s.value; else if (s.tag == 14) g_set.aimSpeed = s.value; else if (s.tag == 21) g_set.bhopStep = s.value; else if (s.tag == 22) g_set.bhopMax = s.value; else if (s.tag == 23) g_set.bhopReset = s.value; else if (s.tag >= 30 && s.tag <= 38) { g_set.vmv[s.tag - 30] = s.value; g_vmForce = true; } else if (s.tag == 39) { g_set.stretchAspect = s.value; g_stTries = 0; } else g_set.head = s.value;
    [self refreshLabels]; saveSettings();
}
static BOOL g_panelClosing = NO;
- (void)plateTapped { [self setPanelOpen:(_panel.hidden || g_panelClosing)]; }
// menu open / close: fade + small scale + slide; opening has a light spring, closing is a quick ease-in
- (void)setPanelOpen:(BOOL)open {
    UIView *pn = _panel;
    // plain struct literals: this build does not link CoreGraphics, so no CGAffineTransform* function calls
    CGFloat sc = open ? 0.92 : 0.95;
    CGAffineTransform away  = (CGAffineTransform){ sc, 0, 0, sc, 0, -10 };     // scale, then move up 10pt
    CGAffineTransform ident = (CGAffineTransform){ 1, 0, 0, 1, 0, 0 };
    if (open) {
        g_panelClosing = NO;
        if (pn.hidden) { pn.alpha = 0; pn.transform = away; pn.hidden = NO; }
        else if (pn.alpha > 0.99) return;
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ pn.alpha = 1; pn.transform = ident; } completion:nil];
    } else {
        if (pn.hidden) return;
        g_panelClosing = YES;
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ pn.alpha = 0; pn.transform = away; }
                         completion:^(BOOL fin) {
            if (!g_panelClosing) return;                        // re-opened while closing
            g_panelClosing = NO; pn.hidden = YES; pn.transform = ident; pn.alpha = 1;
        }];
    }
}
- (void)dumpFieldsTapped { useDumpFields(); }
- (void)learnTapped {
    if (!g_ready) return;
    if (g_learn) { learnFinish(); return; }
    if (g_active < 0 || !k_targets[g_active]) { g_learnMsg = @"learn: no player class yet"; g_msgUntil = CACurrentMediaTime() + 5; return; }
    g_cands.clear(); g_stats.clear(); g_lhave = false;
    scanClass(k_targets[g_active], 0, 0, 0, 0);
    if (k_aim) scanClass(k_aim, 1, 0, 0, 0);
    g_stats.assign(g_cands.size(), Stat());
    g_learn = true; g_learnT0 = CACurrentMediaTime();
}
- (void)hpLearnTapped {
    if (!g_ready) return;
    bool waiting = hpLearnTap();
    [_hpBtn setTitle:waiting ? @"Hit a bot, tap" : @"Learn health" forState:UIControlStateNormal];
}
- (void)dumpTapped {
    if (!g_ready) { _status.text = @"dump: game not ready yet"; return; }
    NSString *d = dumpFirePath();
    UIPasteboard.generalPasteboard.string = d;                                   // may be invisible on your setup, so also:
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"SCESP_dump.txt"];
    [d writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[SCESP] dump (%lu chars) -> %@\n%@", (unsigned long)d.length, path, d);
    UIView *host = _panel.superview ?: _panel;
    if (_dumpView) [_dumpView removeFromSuperview];
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectInset(host.bounds, 12, 60)];
    tv.backgroundColor = [NL_WIN colorWithAlphaComponent:0.98];
    tv.textColor = UIColor.whiteColor; tv.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    tv.editable = NO; tv.selectable = YES; tv.text = d;
    tv.layer.cornerRadius = 10; tv.layer.borderWidth = 1; tv.layer.borderColor = NL_BORDER.CGColor;
    tv.textContainerInset = UIEdgeInsetsMake(34, 8, 8, 8);
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(tv.bounds.size.width - 70, 4, 64, 28);
    [x setTitle:@"Close" forState:UIControlStateNormal];
    [x addTarget:self action:@selector(dumpClose) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:tv]; [host addSubview:x];
    x.frame = CGRectOffset(x.frame, tv.frame.origin.x, tv.frame.origin.y);
    _dumpView = tv; _dumpClose = x;
    _status.text = [NSString stringWithFormat:@"dump: %lu chars, on screen + Documents/SCESP_dump.txt", (unsigned long)d.length];
}
- (void)dumpClose { [_dumpView removeFromSuperview]; [_dumpClose removeFromSuperview]; _dumpView = nil; _dumpClose = nil; }

// Called from a run-loop observer that fires AFTER Unity's frame callback, so bone and camera
// transforms are the ones of the frame that was just rendered (no one-frame lag).
- (void)tick {
    double now = CACurrentMediaTime();
    double minDt = g_set.lowcpu ? 0.030 : 0.0145;
    if (now - _lastTick < minDt) return;
    _lastTick = now;

    UIWindow *win = [self keyWindow];
    if (!win) return;
    if (!_btn) {
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(8, 44, 64, 24);
        _btn.backgroundColor = [NL_WIN colorWithAlphaComponent:0.85];
        _btn.layer.cornerRadius = 7; _btn.layer.borderWidth = 1; _btn.layer.borderColor = [NL_ACCENT colorWithAlphaComponent:0.7].CGColor;
        _btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
        [_btn setTitle:@"SCESP" forState:UIControlStateNormal];
        [_btn setTitleColor:NL_ACCENT forState:UIControlStateNormal];
        [_btn addTarget:self action:@selector(plateTapped) forControlEvents:UIControlEventTouchUpInside];
        [self buildPanel];
    }
    if (_btn.superview != win) { [_btn removeFromSuperview]; [win addSubview:_btn]; }
    if (_panel.superview != win) { [_panel removeFromSuperview]; [win addSubview:_panel]; }
    [win bringSubviewToFront:_panel];
    [win bringSubviewToFront:_btn];

    if (!g_ready) {
        if (_frame++ % 30) return;
        if (!g_apiOk) g_apiOk = loadApi();
        if (!g_apiOk) { _status.text = @"il2cpp API missing"; return; }
        if (!resolveAll()) { _status.text = @"waiting for game classes..."; return; }
        g_ready = true; _lastScan = 0;
    }
    if (!_overlay) {
        _overlay = [[UIView alloc] initWithFrame:win.bounds];
        _overlay.userInteractionEnabled = NO;
        _overlay.backgroundColor = UIColor.clearColor;
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _boxes = [CAShapeLayer layer]; _skel = [CAShapeLayer layer];
        _boxes.fillColor = UIColor.clearColor.CGColor; _skel.fillColor = UIColor.clearColor.CGColor;
        _hpBack = [CAShapeLayer layer]; _hpG = [CAShapeLayer layer]; _hpY = [CAShapeLayer layer]; _hpR = [CAShapeLayer layer];
        _hpBack.fillColor = [UIColor colorWithWhite:0 alpha:0.65].CGColor;
        _hpG.fillColor = [UIColor colorWithRed:0.1 green:1 blue:0.2 alpha:1].CGColor;
        _hpY.fillColor = [UIColor colorWithRed:1 green:0.85 blue:0.1 alpha:1].CGColor;
        _hpR.fillColor = [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:1].CGColor;
        [_overlay.layer addSublayer:_boxes]; [_overlay.layer addSublayer:_skel];
        for (CAShapeLayer *hl in @[_hpBack, _hpG, _hpY, _hpR]) { hl.strokeColor = nil; [_overlay.layer addSublayer:hl]; }
        _arm = [CAShapeLayer layer]; _armFlag = [CAShapeLayer layer];
        _arm.fillColor = [UIColor colorWithRed:0.25 green:0.62 blue:1 alpha:1].CGColor;
        _armFlag.fillColor = [UIColor colorWithRed:1 green:0.82 blue:0.2 alpha:1].CGColor;
        _armFlag.strokeColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor; _armFlag.lineWidth = 1;
        _arm.strokeColor = nil;
        [_overlay.layer addSublayer:_arm]; [_overlay.layer addSublayer:_armFlag];
        _hdot = [CAShapeLayer layer];
        _hdot.strokeColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor; _hdot.lineWidth = 1;
        [_overlay.layer addSublayer:_hdot];
        _fovRing = [CAShapeLayer layer];
        _fovRing.fillColor = UIColor.clearColor.CGColor; _fovRing.lineWidth = 1.2;
        [_overlay.layer addSublayer:_fovRing];
    }
    if (_overlay.superview != win) { [_overlay removeFromSuperview]; [win insertSubview:_overlay belowSubview:_btn]; }

    UIBezierPath *boxPath = [UIBezierPath bezierPath];
    UIBezierPath *skelPath = [UIBezierPath bezierPath];
    UIBezierPath *hpBack = [UIBezierPath bezierPath], *hpG = [UIBezierPath bezierPath], *hpY = [UIBezierPath bezierPath], *hpR = [UIBezierPath bezierPath];
    bool wantHp = g_set.hp && (mi_hp || g_haveHp);
    bool wantArmor = g_set.armor && mi_armor;
    bool wantWep = g_set.wep;
    UIBezierPath *armPath = [UIBezierPath bezierPath], *armFlagPath = [UIBezierPath bezierPath];
    UIBezierPath *dotPath = [UIBezierPath bezierPath];
    UIBezierPath *fovPath = [UIBezierPath bezierPath];
    std::vector<DmgDraw> dd;
    std::vector<BarTxt> bt;
    std::vector<WepTxt> wt;
    int drawn = 0, myTeam = -1;
    bool camOk = false;
    std::vector<void *> wantChams;
    bool scanNow = false;
    void *diagR = nullptr;

    if (g_set.on) {
        if (now - _lastScan > 1.0) { rescan(g_set.skel || g_set.chams || g_set.box || g_set.aim); scanNow = true; _lastScan = now; }
        @try {
            void *cam = d_cam_main(mi_cam_main);
            int sw = d_sw(mi_sw), sh = d_sh(mi_sh);
            if (cam && alive(cam) && sw > 0 && sh > 0) {
                camOk = true;
                void *ctr = d_tr(cam, mi_tr);
                V3 camPos = d_pos(ctr, mi_pos);
                CGSize vs = _overlay.bounds.size;

                struct P { PlayerInfo *pi; void *obj; V3 pos; bool self; };
                std::vector<P> ps;
                for (auto &pi : g_pl) {
                    void *obj = il2_gc_get(pi.obj);
                    if (!alive(obj)) continue;
                    void *tr = d_tr(obj, mi_tr);
                    if (!tr) continue;
                    V3 pos = d_pos(tr, mi_pos);
                    float dx = pos.x - camPos.x, dz = pos.z - camPos.z;
                    ps.push_back({ &pi, obj, pos, dx * dx + dz * dz < kSelfRadius * kSelfRadius });
                }
                if (g_teamField < 0 && !g_teamOffsets.empty()) {
                    for (int f = 0; f < (int)g_teamOffsets.size(); f++) {
                        bool h1 = false, h2 = false;
                        for (auto &p : ps) { int v = readTeam(p.obj, f); if (v == 1) h1 = true; if (v == 2) h2 = true; }
                        if (h1 && h2) { g_teamField = f; break; }
                    }
                }
                for (auto &p : ps) if (p.self && g_teamField >= 0) myTeam = readTeam(p.obj, g_teamField);

                std::vector<AimTg> tg; void *meObj = nullptr; int nBots = 0;
                for (auto &p : ps) if (p.self) meObj = p.obj;
                {   // offline bot match = at least one other character and every other character is a bot
                    int others = 0; bool allBots = true;
                    for (auto &p : ps) { if (p.self) continue; others++; if (!isBotObj(p.obj)) allBots = false; }
                    applyNoSpread(meObj, g_set.nospread, others > 0 && allBots);
                    g_silentOffline = others > 0 && allBots;
                }
                applyBhop(meObj, g_set.bhop);
                applyViewmodel(meObj);
                applyStretch(sw, sh);
                std::vector<CGPoint> sp; std::vector<char> okp;
                for (auto &p : ps) {
                    if (p.self) continue;
                    if (g_teamField >= 0) {
                        int tv = readTeam(p.obj, g_teamField);
                        if (tv != 1 && tv != 2) continue;
                        if (!g_set.team && (myTeam == 1 || myTeam == 2) && tv == myTeam) continue;
                    }
                    PlayerInfo &pi = *p.pi;
                    if (pi.body) { void *r = il2_gc_get(pi.body); if (r) wantChams.push_back(r); }
                    else for (uint32_t h : pi.smr) { void *r = il2_gc_get(h); if (r) wantChams.push_back(r); }

                    size_t nb = pi.bone.size();
                    sp.assign(nb, CGPointMake(0, 0)); okp.assign(nb, 0);
                    float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
                    V3 hw = { 0, 0, 0 }; float hy = -1e9f;
                    int good = 0;
                    V3 partSum[kAimPartCount] = {};
                    int partCount[kAimPartCount] = {};
                    for (size_t b = 0; b < nb; b++) {
                        void *bt = pi.bone[b] ? il2_gc_get(pi.bone[b]) : nullptr;
                        if (!alive(bt)) continue;
                        if (b < pi.skip.size() && pi.skip[b]) continue;
                        V3 w = d_pos(bt, mi_pos);
                        float ex = w.x - p.pos.x, ey = w.y - p.pos.y, ez = w.z - p.pos.z;
                        if (ey < -kBelowFeet || ey > g_set.head + 0.8f || ex * ex + ez * ez > kMaxReach * kMaxReach) continue;
                        int region = b < pi.part.size() ? pi.part[b] : -1;
                        if (region < 0 || region >= kAimPartCount) {
                            bool lateralArm = ey > 0.48f && ey < g_set.head * 0.78f && (ex * ex + ez * ez) > 0.055f;
                            region = lateralArm ? kAimArm : fallbackAimPart(ey, g_set.head);
                        }
                        if (region >= 0 && region < kAimPartCount) {
                            partSum[region].x += w.x; partSum[region].y += w.y; partSum[region].z += w.z;
                            partCount[region]++;
                        }
                        if (w.y > hy) { hy = w.y; hw = w; }
                        V3 s = d_world2screen(cam, w, mi_w2s);
                        if (s.z <= 0) continue;
                        CGFloat x = s.x / sw * vs.width, y = (1.0 - s.y / sh) * vs.height;
                        sp[b] = CGPointMake(x, y); okp[b] = 1; good++;
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                    float hpv = 0;
                    bool needHp = wantHp || ((mi_hp || g_haveHp) && (g_set.dmg || g_set.aim));
                    bool hpOk = needHp && readHp(p.obj, &pi, hpv);
                    if (g_set.dmg && hpOk) {
                        if (g_hpPrev.size() > 128) g_hpPrev.clear();
                        auto it = g_hpPrev.find(p.obj);
                        // "my damage only": the game gives no attacker, so a drop only counts while this character
                        // is under my crosshair (screen box around the bones, padded, must contain the view centre).
                        // Hits a teammate lands on someone I am not looking at are ignored.
                        bool mine = true;
                        if (g_set.dmgMine) {
                            mine = false;
                            if (good >= 2 && maxX > minX) {
                                CGFloat padX = fmax(18.0, (maxX - minX) * 0.15), padY = fmax(18.0, (maxY - minY) * 0.10);
                                CGFloat cx = vs.width * 0.5, cy = vs.height * 0.5;
                                mine = cx >= minX - padX && cx <= maxX + padX && cy >= minY - padY && cy <= maxY + padY;
                            }
                        }
                        if (mine && it != g_hpPrev.end() && hpv < it->second - 0.5f && it->second < 1000.f) {
                            V3 hp3 = hy > -1e8f ? hw : V3{ p.pos.x, p.pos.y + 1.6f, p.pos.z };
                            dmgSpawn(p.obj, { hp3.x, hp3.y + 0.15f, hp3.z }, it->second - hpv, now);
                        }
                        g_hpPrev[p.obj] = hpv;
                    }
                    bool botObj = isBotObj(p.obj);
                    if (botObj) nBots++;
                    {
                        bool dead = hpOk && hpv <= 0.f;                       // never lock on corpses
                        if (!dead && botObj) {                                // aim lock targets bots only
                            AimTg target{};
                            target.pos = hy > -1e8f ? hw : V3{ p.pos.x, p.pos.y + 1.6f, p.pos.z };
                            target.id = p.obj;
                            for (int q = 0; q < kAimPartCount; q++) {
                                if (partCount[q] > 0) {
                                    float invCount = 1.0f / (float)partCount[q];
                                    target.partPos[q] = { partSum[q].x * invCount, partSum[q].y * invCount, partSum[q].z * invCount };
                                    target.partCount[q] = (uint8_t)fminf(255.f, (float)partCount[q]);
                                }
                            }
                            tg.push_back(target);
                        }
                    }
                    bool haveBones = good >= 6;

                    if (g_set.hdot) {      // head dot: highest valid bone, or the pivot + box height when bones are missing
                        V3 h3 = (hy > -1e8f) ? V3{ hw.x, hw.y + 0.04f, hw.z } : V3{ p.pos.x, p.pos.y + g_set.head - 0.12f, p.pos.z };
                        V3 hs3 = d_world2screen(cam, h3, mi_w2s);
                        if (hs3.z > 0) {
                            float ddx = h3.x - camPos.x, ddy = h3.y - camPos.y, ddz = h3.z - camPos.z;
                            float dd = fmaxf(0.5f, sqrtf(ddx * ddx + ddy * ddy + ddz * ddz));
                            CGFloat rad = fmin(14.0, fmax(2.5, 0.11 * vs.height * 0.866 / dd));   // ~11 cm head radius at 60 deg vfov
                            CGFloat dx2 = hs3.x / sw * vs.width, dy2 = (1.0 - hs3.y / sh) * vs.height;
                            [dotPath appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(dx2 - rad, dy2 - rad, rad * 2, rad * 2)]];
                        }
                    }

                    if (g_set.skel && haveBones) {
                        for (size_t b = 0; b < nb; b++) {
                            int par = pi.parent[b];
                            if (par < 0 || !okp[b] || !okp[par]) continue;
                            [skelPath moveToPoint:sp[par]]; [skelPath addLineToPoint:sp[b]];
                        }
                    }
                    if (g_set.box || g_set.fill || wantHp || wantArmor || wantWep) {
                        CGRect r;
                        if (haveBones) {
                            CGFloat pad = 6;
                            r = CGRectMake(minX - pad, minY - pad * 2, (maxX - minX) + pad * 2, (maxY - minY) + pad * 3);
                        } else {
                            V3 head = { p.pos.x, p.pos.y + g_set.head, p.pos.z };
                            V3 a = d_world2screen(cam, head, mi_w2s), b = d_world2screen(cam, p.pos, mi_w2s);
                            if (a.z <= 0 || b.z <= 0) continue;
                            CGFloat hx = a.x / sw * vs.width, hy = (1.0 - a.y / sh) * vs.height;
                            CGFloat fx = b.x / sw * vs.width, fy = (1.0 - b.y / sh) * vs.height;
                            CGFloat bh = fy - hy; if (bh < 4) continue;
                            CGFloat bw = bh * 0.5, cx = (hx + fx) * 0.5;
                            r = CGRectMake(cx - bw / 2, hy, bw, bh);
                        }
                        if (g_set.box || g_set.fill) [boxPath appendPath:[UIBezierPath bezierPathWithRect:r]];
                        float hv = hpv;
                        if (wantHp && hpOk && hv > 0.f && hv < 1e6f) {
                            if (g_hpMax.size() > 128) g_hpMax.clear();
                            float &mx = g_hpMax[p.obj];
                            if (mx < (mi_hp ? 100.f : g_hpRef)) mx = mi_hp ? 100.f : g_hpRef;
                            if (hv > mx) mx = hv;
                            CGFloat ratio = fminf(1.f, hv / mx);
                            CGFloat bw = 2.0, bx = r.origin.x - bw - 3;     // wide enough for the number inside the bar
                            [hpBack appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(bx - 1, r.origin.y - 1, bw + 2, r.size.height + 2)]];
                            CGFloat fh = r.size.height * ratio;
                            UIBezierPath *tgt = ratio > 0.6 ? hpG : (ratio > 0.3 ? hpY : hpR);
                            [tgt appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(bx, r.origin.y + r.size.height - fh, bw, fh)]];
                            bt.push_back({ bx + bw * 0.5, r.origin.y, (int)lroundf(hv), -1, (float)ratio });
                        }
                        // armor bar: right side of the box, blue (the gold odg() flag dot was removed)
                        if (wantArmor && !(hpOk && hpv <= 0.f)) {
                            int av = 0; bool flag = false;
                            if (readArmor(p.obj, av, flag) && av > 0) {
                                CGFloat bw = 2.0, ax = r.origin.x + r.size.width + 3;
                                if (av > 0) {
                                    CGFloat ratio = fminf(1.f, (float)av / 100.f);
                                    [hpBack appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(ax - 1, r.origin.y - 1, bw + 2, r.size.height + 2)]];
                                    CGFloat fh = r.size.height * ratio;
                                    [armPath appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(ax, r.origin.y + r.size.height - fh, bw, fh)]];
                                    bt.push_back({ ax + bw * 0.5, r.origin.y, av, 1, (float)ratio });
                                }
                            }
                        }
                        if (wantWep && !(hpOk && hpv <= 0.f)) {
                            WepTxt w; w.x = r.origin.x + r.size.width * 0.5; w.y = r.origin.y + r.size.height + 2;
                            if (readWeaponName(p.obj, w.s, sizeof(w.s))) wt.push_back(w);
                        }
                    }
                    drawn++;
                }
                // ---- aim FOV outline: a real cone around the view direction (same test the target selection uses) ----
                g_nBots = nBots;
                for (size_t i = 0; i < g_pops.size();) {
                    DmgPop &d = g_pops[i];
                    float age = (float)(now - d.t0), life = 1.15f;
                    if (!g_set.dmg || age > life) { g_pops.erase(g_pops.begin() + i); continue; }
                    V3 s3 = d_world2screen(cam, d.pos, mi_w2s);
                    if (s3.z > 0) {
                        float p = age / life, e = 1.f - (1.f - p) * (1.f - p);          // ease-out
                        CGPoint base = CGPointMake(s3.x / sw * vs.width, (1.0 - s3.y / sh) * vs.height);
                        DmgDraw dr;
                        dr.p = CGPointMake(base.x - 8 - 56 * e, base.y - 6 - 64 * e);   // slides up and to the left of the bot
                        dr.a = p < 0.6f ? 1.f : 1.f - (p - 0.6f) / 0.4f;
                        dr.amt = d.amount;
                        dr.k = age < 0.12f ? 1.35f - 0.35f * (age / 0.12f) : 1.f;       // little pop-in
                        dd.push_back(dr);
                    }
                    i++;
                }
                if (g_set.drawFov && mi_fwd && d_fwd) {
                    V3 f0 = d_fwd(ctr, mi_fwd);
                    float fl = sqrtf(f0.x * f0.x + f0.y * f0.y + f0.z * f0.z);
                    if (fl > 1e-4f) { f0.x /= fl; f0.y /= fl; f0.z /= fl; }
                    V3 r = { f0.z, 0.f, -f0.x };                                   // right = up x forward
                    float rl = sqrtf(r.x * r.x + r.z * r.z);
                    if (rl < 1e-3f) r = { 1.f, 0.f, 0.f }; else { r.x /= rl; r.z /= rl; }
                    V3 u = { f0.y * r.z - f0.z * r.y, f0.z * r.x - f0.x * r.z, f0.x * r.y - f0.y * r.x };   // up = forward x right
                    float th = fminf(g_set.fov, 85.f) * 0.0174533f, ct = cosf(th), st = sinf(th);
                    const int N = 72;
                    bool brk = true;
                    for (int i = 0; i <= N; i++) {
                        float ph = (float)i / N * 6.2831853f, cx = cosf(ph), sy = sinf(ph);
                        V3 d = { f0.x * ct + (r.x * cx + u.x * sy) * st, f0.y * ct + (r.y * cx + u.y * sy) * st, f0.z * ct + (r.z * cx + u.z * sy) * st };
                        V3 wp = { camPos.x + d.x * 20.f, camPos.y + d.y * 20.f, camPos.z + d.z * 20.f };
                        V3 s2 = d_world2screen(cam, wp, mi_w2s);
                        if (s2.z <= 0) { brk = true; continue; }
                        CGPoint pt = CGPointMake(s2.x / sw * vs.width, (1.0 - s2.y / sh) * vs.height);
                        if (brk) { [fovPath moveToPoint:pt]; brk = false; } else [fovPath addLineToPoint:pt];
                    }
                }
                // ---- aim lock / learning (offline) ----
                if (meObj && mi_fwd && d_fwd) {
                    V3 f = d_fwd(ctr, mi_fwd);
                    float curYaw = atan2f(f.x, f.z) * 57.29578f;
                    float curPit = -asinf(fmaxf(-1.f, fminf(1.f, f.y))) * 57.29578f;
                    void *aimObj = localAim(meObj);
                    if (!aimObj) aimObj = nearestAim(camPos);          // fallback only
                    {   // silent aim snapshot (read by silentAimApply from the fire hook)
                        g_silentTargets.clear();
                        if (g_set.silent && g_silentOffline) {
                            g_silentCam = toSA(camPos); g_silentFwd = toSA(f);
                            for (auto &t : tg) {
                                V3 ap = t.pos;
                                if (g_selectedAimPart >= 0 && g_selectedAimPart < kAimPartCount && t.partCount[g_selectedAimPart] > 0)
                                    ap = t.partPos[g_selectedAimPart];
                                silent_aim::Target st;
                                st.entity = (std::uintptr_t)t.id; st.aimPoint = toSA(ap);
                                st.alive = true; st.enemy = true; st.visible = true;   // tg already holds live enemies only
                                g_silentTargets.push_back(st);
                            }
                        }
                        g_silentFresh = true;
                    }
                    if (g_learn) {
                        learnStep(meObj, aimObj, curYaw, curPit);
                        if (now - g_learnT0 > 6.0) learnFinish();
                        else g_learnMsg = [NSString stringWithFormat:@"learning %.0fs: turn LEFT/RIGHT and UP/DOWN", 6.0 - (now - g_learnT0)];
                    } else if (g_probeAxis >= 0) {
                        probeStep(meObj, aimObj, curYaw, curPit, now);
                    } else if (g_set.aim && g_haveYaw && g_havePit && !tg.empty()) {
                        double dt = fmin(0.05, fmax(0.004, now - g_aimLastW));
                        g_aimLastW = now;
                        float best = 1e9f, dyB = 0, dpB = 0; bool got = false; void *bestId = nullptr;
                        for (auto &t : tg) {
                            V3 targetPos = t.pos;
                            if (g_selectedAimPart >= 0 && g_selectedAimPart < kAimPartCount && t.partCount[g_selectedAimPart] > 0)
                                targetPos = t.partPos[g_selectedAimPart];
                            float dx = targetPos.x - camPos.x, dy = targetPos.y - camPos.y, dz = targetPos.z - camPos.z;
                            float len = sqrtf(dx * dx + dy * dy + dz * dz);
                            if (len < 0.5f) continue;
                            float ey = wrap180(atan2f(dx, dz) * 57.29578f - curYaw), ep = -asinf(dy / len) * 57.29578f - curPit;
                            float e = acosf(fmaxf(-1.f, fminf(1.f, (f.x * dx + f.y * dy + f.z * dz) / len))) * 57.29578f;   // true angle to the view direction
                            bool cur = t.id && t.id == g_lockId;
                            if (e > g_set.fov * (cur ? 1.3f : 1.0f)) continue;      // hysteresis: a locked target may drift out a bit further
                            float score = cur ? e * 0.55f : e;                      // sticky: only switch when another bot is clearly closer
                            if (score < best) { best = score; dyB = ey; dpB = ep; got = true; bestId = t.id; }
                        }
                        g_lockId = got ? bestId : nullptr;
                        if (got) aimStep(meObj, aimObj, dyB, dpB, (float)dt);
                    }
                }
            }
        } @catch (...) {}
    }

    {
        bool wantOcc = g_set.on && g_set.noocc && (g_set.chams || g_set.skel);
        @try {
            if (scanNow || g_dirty) {
                if (wantOcc) { setOcclusion(true); forceVisible(true); }
                else if (g_occOff) setOcclusion(false);
            } else if (wantOcc && g_occOff) {
                forceVisible(false);    // every tick: the game flips renderers back off on hit / state change
            }
        } @catch (...) {}
    }

    if (!wantChams.empty()) diagR = wantChams[0];
    {   // CommandBuffer chams every tick (cheap: only re-records when the list changes)
        bool cbOn = false;
        @try {
            std::vector<void *> wc;
            if (g_set.on && g_set.chams) wc = wantChams;
            if (wc.empty()) { if (g_cb) cbClear(); }
            else cbOn = cbUpdate((mi_cam_main && d_cam_main) ? d_cam_main(mi_cam_main) : nullptr, wc);
        } @catch (...) {}
        g_cbActive = cbOn;
    }
    if (g_dirty || scanNow || !g_set.on) {
        @try {
            if (!g_set.on || !g_set.chams || g_cbActive) wantChams.clear();   // buffer path active -> undo any material swaps
            reconcileChams(wantChams);
            if (g_dirty) updateChamColor();
        } @catch (...) {}
        g_dirty = false;
    }
    @try { if (g_set.on && g_set.chams && !g_cbActive && !g_chams.empty() && (++_vfy % 6 == 0)) verifyChams(); } @catch (...) {}
    @try { pumpChamZTest(); } @catch (...) {}

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _boxes.frame = _overlay.bounds; _skel.frame = _overlay.bounds;
    _boxes.strokeColor = g_set.box ? colorFor(g_set.color, 1).CGColor : UIColor.clearColor.CGColor;
    _boxes.fillColor = g_set.fill ? colorFor(g_set.color, 0.18).CGColor : UIColor.clearColor.CGColor;
    _skel.strokeColor = colorFor(g_set.color, 1).CGColor;
    _boxes.lineWidth = g_set.lw; _skel.lineWidth = g_set.lw;
    _boxes.path = boxPath.CGPath; _skel.path = skelPath.CGPath;
    for (CAShapeLayer *hl in @[_hpBack, _hpG, _hpY, _hpR]) hl.frame = _overlay.bounds;
    _fovRing.frame = _overlay.bounds; _fovRing.path = fovPath.CGPath;
    _fovRing.strokeColor = ((g_set.aim && g_lockId) ? nlRGB(70, 255, 120, 0.95) : nlRGB(61, 166, 255, 0.75)).CGColor;
    _hdot.frame = _overlay.bounds; _hdot.path = dotPath.CGPath; _hdot.fillColor = colorFor(g_set.color, 1).CGColor;
    _hpBack.path = hpBack.CGPath; _hpG.path = hpG.CGPath; _hpY.path = hpY.CGPath; _hpR.path = hpR.CGPath;
    _arm.frame = _overlay.bounds; _armFlag.frame = _overlay.bounds;
    _arm.path = armPath.CGPath; _armFlag.path = armFlagPath.CGPath;
    if (!_dmgLabels) _dmgLabels = [NSMutableArray array];
    while (_dmgLabels.count < 10) {
        UILabel *dl = [[UILabel alloc] init];
        dl.hidden = YES; dl.userInteractionEnabled = NO; dl.textAlignment = NSTextAlignmentCenter;
        dl.shadowColor = [UIColor colorWithWhite:0 alpha:0.9]; dl.shadowOffset = CGSizeMake(1, 1);
        [_overlay addSubview:dl]; [_dmgLabels addObject:dl];
    }
    for (NSUInteger i = 0; i < _dmgLabels.count; i++) {
        UILabel *dl = _dmgLabels[i];
        if (i >= dd.size()) { dl.hidden = YES; continue; }
        const DmgDraw &dr = dd[i];
        int amt = (int)lroundf(dr.amt);
        dl.text = [NSString stringWithFormat:@"-%d", amt];
        dl.font = [UIFont systemFontOfSize:(13.f + fminf(dr.amt, 100.f) * 0.09f) * dr.k weight:UIFontWeightHeavy];
        dl.textColor = dr.amt >= 60 ? nlRGB(255, 70, 70) : (dr.amt >= 30 ? nlRGB(255, 205, 70) : UIColor.whiteColor);
        [dl sizeToFit];
        dl.center = dr.p; dl.alpha = dr.a; dl.hidden = NO;
    }
    // hp / armor numbers next to the bars (hp left of its bar, armor right of its bar)
    if (!_barLabels) _barLabels = [NSMutableArray array];
    if (bt.size() > 80) bt.resize(80);
    while (_barLabels.count < bt.size()) {
        UILabel *bl = [[UILabel alloc] init];
        bl.hidden = YES; bl.userInteractionEnabled = NO;
        bl.font = [UIFont monospacedDigitSystemFontOfSize:8 weight:UIFontWeightHeavy];
        bl.shadowColor = [UIColor colorWithWhite:0 alpha:0.95]; bl.shadowOffset = CGSizeMake(1, 1);
        [_overlay addSubview:bl]; [_barLabels addObject:bl];
    }
    for (NSUInteger i = 0; i < _barLabels.count; i++) {
        UILabel *bl = _barLabels[i];
        if (i >= bt.size()) { bl.hidden = YES; continue; }
        const BarTxt &t = bt[i];
        bl.text = [NSString stringWithFormat:@"%d", t.v];
        bl.textColor = UIColor.whiteColor;                        // white on the bar, black shadow keeps it readable on any fill
        [bl sizeToFit];
        CGRect f = bl.frame; f.origin.y = t.y + 1;               // inside the bar, at its top
        f.origin.x = t.x - f.size.width * 0.5;                   // centred on the bar
        bl.frame = f; bl.hidden = NO;
    }
    // weapon names under the boxes
    if (!_wepLabels) _wepLabels = [NSMutableArray array];
    if (wt.size() > 40) wt.resize(40);
    while (_wepLabels.count < wt.size()) {
        UILabel *wl = [[UILabel alloc] init];
        wl.hidden = YES; wl.userInteractionEnabled = NO;
        wl.font = [UIFont systemFontOfSize:9 weight:UIFontWeightHeavy];
        wl.textColor = UIColor.whiteColor; wl.textAlignment = NSTextAlignmentCenter;
        wl.shadowColor = [UIColor colorWithWhite:0 alpha:0.95]; wl.shadowOffset = CGSizeMake(1, 1);
        [_overlay addSubview:wl]; [_wepLabels addObject:wl];
    }
    for (NSUInteger i = 0; i < _wepLabels.count; i++) {
        UILabel *wl = _wepLabels[i];
        if (i >= wt.size()) { wl.hidden = YES; continue; }
        wl.text = [NSString stringWithUTF8String:wt[i].s];
        [wl sizeToFit];
        wl.center = CGPointMake(wt[i].x, wt[i].y + wl.bounds.size.height * 0.5);
        wl.hidden = NO;
    }
    [CATransaction commit];

    if (!_panel.hidden) {
        _bhopInfo.text = g_bhopMsg;
        _vmInfo.text = g_vmMsg;
        _stInfo.text = g_stMsg;
        _vmInfo.text = [g_vmMsg stringByAppendingFormat:@"\n%@", g_nsMsg];
        NSMutableString *cs = [NSMutableString string];
        for (int i = 0; i < kN; i++) [cs appendFormat:@"%s%zu", i ? "/" : "", g_counts[i]];
        NSString *sh = g_chamShaderUsed ? [NSString stringWithUTF8String:g_chamShaderUsed] : (g_chamFailed ? @"no shader" : @"-");
        _status.text = [NSString stringWithFormat:@"found %@ | team f%d me%d | draw %d | cam %@\nchams %@ %s %zu re%d | occ %s",
                        cs, g_teamField, myTeam, drawn, camOk ? @"ok" : @"-", [sh lastPathComponent],
                        g_chamMode == 2 ? "noX" : (g_cbActive ? "xray+cb" : "xray"), g_chams.size(), g_chamReapply,
                        g_occOff ? "off" : "on"];
        @try {
            NSString *l3 = (g_learn || now < g_msgUntil) ? g_learnMsg
                         : (g_set.aim ? ((g_haveYaw && g_havePit) ? [NSString stringWithFormat:@"aim: ON, bots %d%@", g_nBots, g_nBots ? @"" : @" (none: no lock)"] : @"aim: ON but NOT learned -> Learn look fields")
                                      : diagRenderer(diagR));
            _status.text = [_status.text stringByAppendingFormat:@"\n%@\n%@", l3, mi_hp ? (mi_armor ? @"hp: ode() | armor: odf()/odg()" : @"hp: PlayerController.ode() | armor: n/a") : g_hpMsg];
            _aimInfo.text = l3;
        } @catch (...) {}
    }
}
@end

static SCESPDriver *g_driver;

typedef void *(*cf_obs_create)(void *alloc, unsigned long activities, bool repeats, long order, void (^block)(void *obs, unsigned long act));
typedef void *(*cf_main_loop)(void);
typedef void (*cf_add_obs)(void *rl, void *obs, void *mode);

__attribute__((constructor)) static void scesp_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        loadSettings();
        loadAim();
        if (!(g_haveYaw && g_havePit)) useDumpFields();
        loadHp();
        g_driver = [SCESPDriver new];
        // CoreFoundation is resolved at runtime so the dylib needs no extra link flags.
        cf_obs_create create = (cf_obs_create)dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreateWithHandler");
        cf_main_loop mainLoop = (cf_main_loop)dlsym(RTLD_DEFAULT, "CFRunLoopGetMain");
        cf_add_obs addObs = (cf_add_obs)dlsym(RTLD_DEFAULT, "CFRunLoopAddObserver");
        void **commonModes = (void **)dlsym(RTLD_DEFAULT, "kCFRunLoopCommonModes");
        if (create && mainLoop && addObs && commonModes) {
            // kCFRunLoopBeforeWaiting = 1 << 5
            void *obs = create(nullptr, (1UL << 5), true, 0, ^(void *o, unsigned long act) { [g_driver tick]; });
            addObs(mainLoop(), obs, *commonModes);
            NSLog(@"[SCESP] loaded (runloop observer)");
        } else {
            CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(tick)];
            dl.preferredFramesPerSecond = 60;
            [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            NSLog(@"[SCESP] loaded (display link fallback)");
        }
    });
}
