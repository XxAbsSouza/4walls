package com.fourwalls.backend.shared.tenant;

import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

public final class HouseholdContextHolder {

    private static final ThreadLocal<UUID> CONTEXT =
            new ThreadLocal<>();

    public static void set(UUID householdId) {
        CONTEXT.set(Objects.requireNonNull(householdId));
    }

    public static Optional<UUID> current() {
        return Optional.ofNullable(CONTEXT.get());
    }

    public static UUID require() {
        return current().orElseThrow(
                () -> new IllegalStateException(
                        "Household context is not available"
                )
        );
    }

    public static void clear() {
        CONTEXT.remove();
    }

    private HouseholdContextHolder() {}
}