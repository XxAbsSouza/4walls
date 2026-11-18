package com.fourwalls.backend.shared.tenant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.MountableFile;

@SpringBootTest
@Testcontainers
class HouseholdRlsIntegrationTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withCopyFileToContainer(
                    MountableFile.forHostPath("../infra/sql/00_bootstrap.local.sql"),
                    "/docker-entrypoint-initdb.d/00_bootstrap.sql");
    @DynamicPropertySource
    static void databaseProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", () -> "fourwalls_app");
        registry.add("spring.datasource.password", () -> "dev_app");
        registry.add("spring.datasource.hikari.maximum-pool-size", () -> 1);

        registry.add("spring.flyway.url", POSTGRES::getJdbcUrl);
        registry.add("spring.flyway.user", () -> "fourwalls_migrator");
        registry.add("spring.flyway.password", () -> "dev_migrator");
        registry.add("spring.flyway.default-schema", () -> "app");
        registry.add("spring.flyway.schemas", () -> "app");
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired TransactionTemplate tx;
    @Autowired PlatformTransactionManager transactionManager;

    UUID householdA;
    UUID householdB;

    @BeforeEach
    void createHouseholds() {
        householdA = createHouseholdWithDefaultCategories("Lar A");
        householdB = createHouseholdWithDefaultCategories("Lar B");
    }

    @AfterEach
    void clearContext() {
        HouseholdContextHolder.clear();
    }

    // ------------------------------------------------------------------
    // Configuração: as peças certas estão no lugar?
    // ------------------------------------------------------------------

    @Test
    void springUsesOurTransactionManager() {
        assertThat(transactionManager).isInstanceOf(HouseholdAwareTransactionManager.class);
    }

    @Test
    void appConnectsAsRestrictedRole() {
        String user = jdbc.queryForObject("select current_user", String.class);
        assertThat(user).isEqualTo("fourwalls_app");
    }

    // ------------------------------------------------------------------
    // Comportamento: o teste 4 manual, automatizado
    // ------------------------------------------------------------------

    @Test
    void withoutHousehold_seesNothing() {
        Long count = tx.execute(status ->
                jdbc.queryForObject("select count(*) from category", Long.class));

        assertThat(count).isZero();
    }

    @Test
    void withHousehold_seesOnlyItsOwnRows() {
        List<UUID> owners = inHousehold(householdA, () ->
                jdbc.queryForList("select distinct household_id from category", UUID.class));

        assertThat(owners).containsExactly(householdA);
    }

    @Test
    void cannotWriteIntoAnotherHousehold() {
        assertThatThrownBy(() -> inHousehold(householdA, () ->
                jdbc.queryForList("select seed_default_categories(?)", householdB)))
                .isInstanceOf(DataAccessException.class)
                .rootCause()
                .hasMessageContaining("row-level security");
    }

    @Test
    void householdDoesNotLeakToNextTransactionOnSameConnection() {
        inHousehold(householdA, () ->
                jdbc.queryForObject("select current_household_id()", UUID.class));

        UUID leaked = tx.execute(status ->
                jdbc.queryForObject("select current_household_id()", UUID.class));

        assertThat(leaked).isNull();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private <T> T inHousehold(UUID householdId, Supplier<T> work) {
        HouseholdContextHolder.set(householdId);
        try {
            return tx.execute(status -> work.get());
        } finally {
            HouseholdContextHolder.clear();
        }
    }

    private UUID createHouseholdWithDefaultCategories(String name) {
        UUID id = jdbc.queryForObject(
                "insert into household (name) values (?) returning id", UUID.class, name);
        inHousehold(id, () -> jdbc.queryForList("select seed_default_categories(?)", id));
        return id;
    }
}
