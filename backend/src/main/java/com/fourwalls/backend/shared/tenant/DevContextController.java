package com.fourwalls.backend.shared.tenant;

import java.util.Map;

import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@Profile("dev")
public class DevContextController {

    private final JdbcTemplate jdbc;

    public DevContextController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping("/dev/context")
    @Transactional(readOnly = true)
    public Map<String, Object> context() {
        return jdbc.queryForMap("""
                select current_user                                       as db_user,
                       current_setting('app.current_household_id', true)  as household_setting,
                       current_household_id()                             as household_function,
                       (select count(*) from category)                    as visible_categories
                """);
    }
}