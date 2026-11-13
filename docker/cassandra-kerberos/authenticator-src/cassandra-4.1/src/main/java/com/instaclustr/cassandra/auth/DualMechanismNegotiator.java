// Usage Notice: This project is not meant for commercial use without permission and proper credit.
// Author: j.martinez.poblete@gmail.com
//
// Routes one SASL exchange to either:
//   - GSSAPI: delegated unchanged to the existing Kerberos negotiator (ring clients), or
//   - PLAIN (RFC 4616 "\0user\0password"): accepted ONLY for the principal "trino"
//     and ONLY if the MIT KDC accepts the password (KdcPasswordValidator).
// Fails closed: any PLAIN problem throws AuthenticationException. The password is never logged.
package com.instaclustr.cassandra.auth;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import org.apache.cassandra.auth.AuthenticatedUser;
import org.apache.cassandra.auth.IAuthenticator.SaslNegotiator;
import org.apache.cassandra.exceptions.AuthenticationException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class DualMechanismNegotiator implements SaslNegotiator
{
    private static final Logger logger = LoggerFactory.getLogger(DualMechanismNegotiator.class);

    // Full principal, matching the Cassandra role name (trino@WAREHOUSE.LAB).
    // Only this exact principal may use PLAIN; everything else is rejected before the KDC.
    static final String PLAIN_PRINCIPAL = "trino@WAREHOUSE.LAB";
    static final String REALM = "WAREHOUSE.LAB";

    private enum Mechanism { UNDECIDED, GSSAPI, PLAIN }

    private final SaslNegotiator gssapi;   // existing KerberosSaslAuthenticator path, unchanged
    private Mechanism mechanism = Mechanism.UNDECIDED;
    private AuthenticatedUser plainUser;
    private boolean plainComplete;

    public DualMechanismNegotiator(final SaslNegotiator gssapi)
    {
        this.gssapi = gssapi;
    }

    @Override
    public byte[] evaluateResponse(final byte[] clientResponse) throws AuthenticationException
    {
        if (clientResponse == null || clientResponse.length == 0)
            throw new AuthenticationException("empty SASL response");

        // Decide the mechanism once, on the first response, and never switch afterwards.
        // RFC 4616 PLAIN starts with NUL; a GSSAPI token (ASN.1/SPNEGO) never does.
        if (mechanism == Mechanism.UNDECIDED)
            mechanism = (clientResponse[0] == 0) ? Mechanism.PLAIN : Mechanism.GSSAPI;

        switch (mechanism)
        {
            case GSSAPI:
                return gssapi.evaluateResponse(clientResponse);
            case PLAIN:
                return evaluatePlain(clientResponse);
            default:
                throw new AuthenticationException("unsupported SASL negotiation state");
        }
    }

    private byte[] evaluatePlain(final byte[] clientResponse) throws AuthenticationException
    {
        if (plainComplete)
            throw new AuthenticationException("PLAIN negotiation already complete");
        String[] parts = new String(clientResponse, StandardCharsets.UTF_8).split("\0", -1);
        if (parts.length != 3)
            throw new AuthenticationException("malformed PLAIN response");

        final String authzid = parts[0];
        final String authcid = parts[1];
        final char[] password = parts[2].toCharArray();
        try
        {
            if (!authzid.isEmpty() && !authzid.equals(authcid))
                throw new AuthenticationException("PLAIN authzid not permitted");

            if (!PLAIN_PRINCIPAL.equals(authcid))
            {
                logger.warn("PLAIN rejected principal {}", authcid);
                throw new AuthenticationException("PLAIN not permitted for this principal");
            }

            // KdcPasswordValidator takes the bare name and appends @REALM itself.
            final String bare = authcid.substring(0, authcid.indexOf('@'));
            if (!KdcPasswordValidator.validate(bare, password, REALM))
            {
                logger.warn("PLAIN KDC password check failed for {}", authcid);
                throw new AuthenticationException("invalid credentials");
            }

            plainUser = new AuthenticatedUser(authcid);
            plainComplete = true;
            // DIAGNOSTIC (temporary): record what Cassandra sees for this principal.
            logger.info("DIAG principal={} primaryRole={} canLogin={} isSuper={}",
                        authcid,
                        plainUser.getPrimaryRole().getRoleName(),
                        plainUser.canLogin(),
                        plainUser.isSuper());
            // DIAGNOSTIC (temporary): raw row count from the same SELECT Cassandra uses.
            try
            {
                org.apache.cassandra.cql3.UntypedResultSet rs =
                    org.apache.cassandra.cql3.QueryProcessor.executeInternal(
                        "SELECT role, can_login, is_superuser FROM system_auth.roles WHERE role = ?", authcid);
                logger.info("DIAG rawRows={}", rs.size());
                // Count ALL roles visible to the internal read, to test whether it sees any rows.
                org.apache.cassandra.cql3.UntypedResultSet all =
                    org.apache.cassandra.cql3.QueryProcessor.executeInternal("SELECT role FROM system_auth.roles");
                logger.info("DIAG allRolesVisibleInternally={}", all.size());
                for (org.apache.cassandra.cql3.UntypedResultSet.Row row : rs)
                    logger.info("DIAG row role={} can_login={} is_super={}",
                                row.getString("role"), row.getBoolean("can_login"), row.getBoolean("is_superuser"));
            }
            catch (Throwable t)
            {
                logger.info("DIAG rawRead threw {}", t.toString());
            }
            logger.info("PLAIN authenticated {}", authcid);
            return null;
        }
        finally
        {
            Arrays.fill(password, '\0');
        }
    }

    @Override
    public boolean isComplete()
    {
        if (mechanism == Mechanism.GSSAPI)
            return gssapi.isComplete();
        return plainComplete;
    }

    @Override
    public AuthenticatedUser getAuthenticatedUser() throws AuthenticationException
    {
        if (mechanism == Mechanism.GSSAPI)
            return gssapi.getAuthenticatedUser();
        if (!plainComplete)
            throw new AuthenticationException("negotiation not complete");
        return plainUser;
    }
}
