// Usage Notice: This project is not meant for commercial use without permission and proper credit.
// Author: j.martinez.poblete@gmail.com
//
// Validates a Kerberos user password against the MIT KDC for PLAIN SASL.
// Uses a user (password) JAAS login, NOT the service keytab used by the GSSAPI path.
package com.instaclustr.cassandra.auth;

import java.util.HashMap;
import java.util.Map;

import javax.security.auth.Subject;
import javax.security.auth.callback.Callback;
import javax.security.auth.callback.CallbackHandler;
import javax.security.auth.callback.NameCallback;
import javax.security.auth.callback.PasswordCallback;
import javax.security.auth.login.AppConfigurationEntry;
import javax.security.auth.login.Configuration;
import javax.security.auth.login.LoginContext;
import javax.security.auth.login.LoginException;

// Performs an AS-REQ for principal@REALM with the supplied password.
// Returns true only if the KDC accepts the password. Never stores the password.
public final class KdcPasswordValidator
{
    private static final String JAAS_ENTRY = "CassandraKdcPasswordCheck";

    private KdcPasswordValidator() {}

    static String loginModuleName()
    {
        // Same module selection logic as BaseKerberosAuthenticator.
        return System.getProperty("java.vendor", "").contains("IBM")
            ? "com.ibm.security.auth.module.Krb5LoginModule"
            : "com.sun.security.auth.module.Krb5LoginModule";
    }

    public static boolean validate(final String principal, final char[] password, final String realm)
    {
        final Map<String, String> options = new HashMap<>();
        options.put("useKeyTab", "false");
        options.put("storeKey", "false");
        // Do NOT set doNotPrompt: with it set, Krb5LoginModule never calls the
        // CallbackHandler for the password, so the AS-REQ carries no credential.
        // The handler answers the password callback from memory (no terminal prompt).
        options.put("refreshKrb5Config", "true");
        options.put("principal", principal + "@" + realm);

        final Configuration jaas = new Configuration()
        {
            @Override
            public AppConfigurationEntry[] getAppConfigurationEntry(final String name)
            {
                return new AppConfigurationEntry[]{
                    new AppConfigurationEntry(loginModuleName(),
                                              AppConfigurationEntry.LoginModuleControlFlag.REQUIRED,
                                              options)
                };
            }
        };

        final CallbackHandler handler = callbacks -> {
            for (final Callback cb : callbacks)
            {
                if (cb instanceof NameCallback)
                    ((NameCallback) cb).setName(principal);
                else if (cb instanceof PasswordCallback)
                    ((PasswordCallback) cb).setPassword(password.clone());
                else
                    throw new javax.security.auth.callback.UnsupportedCallbackException(cb);
            }
        };

        LoginContext lc = null;
        try
        {
            lc = new LoginContext(JAAS_ENTRY, new Subject(), handler, jaas);
            lc.login();
            return true;
        }
        catch (LoginException e)
        {
            return false;
        }
        finally
        {
            if (lc != null)
            {
                try { lc.logout(); } catch (LoginException ignored) { }
            }
        }
    }
}
