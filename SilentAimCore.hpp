#pragma once

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
