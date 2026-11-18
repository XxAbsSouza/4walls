package com.fourwalls.backend.shared.tenant;

import java.util.Optional;
import java.util.UUID;

import org.springframework.core.task.TaskDecorator;
import org.springframework.stereotype.Component;

@Component
public class HouseholdContextTaskDecorator implements TaskDecorator {

    @Override
    public Runnable decorate(Runnable task) {
        Optional<UUID> captured = HouseholdContextHolder.current();

        return () -> {
            Optional<UUID> previous = HouseholdContextHolder.current();

            apply(captured);
            try {
                task.run();
            } finally {
                apply(previous);
            }
        };
    }
    private static void apply(Optional<UUID> householdId) {
        householdId.ifPresentOrElse(
                HouseholdContextHolder::set,
                HouseholdContextHolder::clear
        );
    }
}