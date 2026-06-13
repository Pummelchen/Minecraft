# Custom Self Signed Certificate


In order to use Self signed certificate for WebTransport on the Web, there are some strict rules to validate.

The Self signed certificate MUST not have an expirery date longer than 14 days.
You must always provide the Certificate HASH to the Client (Using the JS WebTransport constructor)
