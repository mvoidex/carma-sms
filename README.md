carma-sms
=========

SMS posting for carma

Start process:
<pre>
carma-sms -u user -p password
</pre>

Then send sms:
<pre>
redis&gt; hmset sms:1 from me phone 70001234567 msg "test message"
redis&gt; lpush smspost sms:1
</pre>

SMS object
----------

SMS object stored in redis has following format:

* from - sender
* phone - receiver, contains only digits
* msg - message in UTF-8
* action - filled by process, send or status
* msgid - filled by process, message id in smsdirect
* status - filled by process, message status, delivered, sent or send_error
* lasttry: timestamp of last try
* tries: number of tries

When carma-sms fails to send (or get status) sms, it pushes sms to retry-list (smspost:retry by default).

After that another thread will push these sms's back to 'smspost'-list periodically until it succeeded or number of tries exceeded
