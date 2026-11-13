// Usage Notice: This project is not meant for commercial use without permission and proper credit.
// Author: j.martinez.poblete@gmail.com
//
// FEASIBILITY SPIKE ONLY. Not for the ring. Verifies that a Cassandra 4.1.12 node
// can run a PLAIN SASL negotiation supplied by an IAuthenticator and reports what
// the client-requested mechanism looks like on the server side.
package com.instaclustr.cassandra.auth;

import java.net.InetAddress;
import java.nio.charset.StandardCharsets;

import org.apache.cassandra.auth.AuthenticatedUser;
import org.apache.cassandra.exceptions.AuthenticationException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

// Accepts exactly one PLAIN exchange: "\0username\0password". Spike only: the password
// check is a placeholder that accepts only the expected principal. The real version
// validates against the KDC (Krb5LoginModule), see docs/cassandra-trino-auth-design.md.
public class PlainSpikeNegotiator implements org.apache.cassandra.auth.IAuthenticator.SaslNegotiator
{
    private static final Logger logger = LoggerFactory.getLogger(PlainSpikeNegotiator.class);
    static final String ALLOWED_USER = "trino";

    private AuthenticatedUser user;
    private boolean complete;

    @Override
    public byte[] evaluateResponse(byte[] clientResponse) throws AuthenticationException
    {
        logger.info("SPIKE PLAIN evaluateResponse, bytes={}", clientResponse == null ? -1 : clientResponse.length);
        if (clientResponse == null)
            throw new AuthenticationException("SPIKE: empty PLAIN response");

        // RFC 4616: authzid NUL authcid NUL passwd
        String[] parts = new String(clientResponse, StandardCharsets.UTF_8).split("\0", -1);
        if (parts.length != 3)
            throw new AuthenticationException("SPIKE: malformed PLAIN response");

        String authcid = parts[1];
        if (!ALLOWED_USER.equals(authcid))
        {
            logger.warn("SPIKE PLAIN rejected principal {}", authcid);
            throw new AuthenticationException("SPIKE: PLAIN not permitted for " + authcid);
        }

        this.user = new AuthenticatedUser(authcid);
        this.complete = true;
        return null;
    }

    @Override
    public boolean isComplete()
    {
        return complete;
    }

    @Override
    public AuthenticatedUser getAuthenticatedUser() throws AuthenticationException
    {
        if (!complete)
            throw new AuthenticationException("SPIKE: negotiation not complete");
        return user;
    }
}
