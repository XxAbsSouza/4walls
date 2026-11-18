package com.fourwalls.backend.shared.tenant;

import java.io.IOException;
import java.util.UUID;

import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@Component
@Profile("dev")
public class DevHouseholdHeaderFilter extends OncePerRequestFilter {

    static final String HEADER = "X-Household-Id";

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        UUID householdId = null;
        String raw = request.getHeader(HEADER);

        if (raw != null && !raw.isBlank()) {
            try {
                householdId = UUID.fromString(raw.trim());
            } catch (IllegalArgumentException e) {
                response.sendError(HttpServletResponse.SC_BAD_REQUEST,
                        "Invalid " + HEADER);
                return;
            }
        }
        try {
            if (householdId != null) {
                HouseholdContextHolder.set(householdId);
            }
            chain.doFilter(request, response);
        } finally {
            HouseholdContextHolder.clear();
        }
    }
}
