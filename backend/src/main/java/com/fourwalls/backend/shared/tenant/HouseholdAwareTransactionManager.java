package com.fourwalls.backend.shared.tenant;


import java.sql.PreparedStatement;
import java.util.UUID;

import org.hibernate.Session;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.transaction.CannotCreateTransactionException;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import jakarta.persistence.EntityManagerFactory;

//template Method
public class HouseholdAwareTransactionManager extends JpaTransactionManager {
    private static final String SET_HOUSEHOLD_SQL =
            "select set_config('app.current_household_id', ?, true)";

    public HouseholdAwareTransactionManager(EntityManagerFactory emf) {
        super(emf);
    }

    @Override
    protected void doBegin(Object transaction, TransactionDefinition definition) {
        super.doBegin(transaction, definition);
        HouseholdContextHolder.current().ifPresent(householdId -> {
            try {
                applyToCurrentTransaction(householdId);
            } catch (RuntimeException e) {
                doCleanupAfterCompletion(transaction);
                throw new CannotCreateTransactionException(
                        "Could not set household context on transaction", e);
            }
        });
    }

    private void applyToCurrentTransaction(UUID householdId) {
        EntityManagerHolder holder = (EntityManagerHolder)
                TransactionSynchronizationManager.getResource(obtainEntityManagerFactory());
        holder.getEntityManager()
                .unwrap(Session.class)
                .doWork(connection -> {
                    try (PreparedStatement ps = connection.prepareStatement(SET_HOUSEHOLD_SQL)) {
                        ps.setString(1, householdId.toString());
                        ps.execute();
                    }
                });
    }
}