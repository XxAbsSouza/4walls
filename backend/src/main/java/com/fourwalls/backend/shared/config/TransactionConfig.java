package com.fourwalls.backend.shared.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import com.fourwalls.backend.shared.tenant.HouseholdAwareTransactionManager;

import jakarta.persistence.EntityManagerFactory;

@Configuration
public class TransactionConfig {

    @Bean
    public PlatformTransactionManager transactionManager(EntityManagerFactory emf) {
        return new HouseholdAwareTransactionManager(emf);
    }
}
