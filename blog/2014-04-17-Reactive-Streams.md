---
layout: post
title: 'Reactive Streams'
author: normanmaurer
---

As some of you may hopefully noticed, today [Reactive Streams](http://www.reactive-streams.org) was announced and left stealth-mode. The idea of the [Reactive Streams](http://www.reactive-streams.org) project is to provide a well defined SPI/API for asynchronous processing of data with back pressure built in. This will make it quite easy to bridge different asynchronous frameworks together and so pass data from one to the other and vice versa.  And all will backpressure etc working out of the box without the need to have it implement by the user himself. 

# Vert.x and Reactive Streams
As [Vert.x](http://vertx.io) is one of these asynchronous frameworks / platforms that runs on the JVM we are already working on a prototype that allows [Vert.x](http://vertx.io) to be used with the propsed SPI/API. While the prototype is currently mainly focused on the AsyncFile I'm quite certain that other areas of [Vert.x](http://vertx.io) will follow once all the details are worked out and the SPI/API has stabilized.

Providing such a unified abstraction offers a lot of freedom to the user and simplifies the use of different projects that implement it.

For example once [Vert.x](http://vertx.io), [Akka](http://akka.io), [RxJava](https://github.com/Netflix/RxJava) and [Reactor](https://github.com/reactor/reactor) all support it, passing data from one to the others would be as easy as here: 

<pre class="syntax java">
vertx.fileSystem().open("/path/to/file", new Handler&lt;AsyncResult&lt;AsyncFile&gt;&gt;() {
    @Override
    public void handle(AsyncResult&lt;AsyncFile&gt; result) {
        if (result.successed()) {
            AsyncFile file = result.result();
            file.produceTo(akkaStream).produceTo(rxjavaObservable).produceTo(reactorStream);
        } else {
            // handle error
        }
    }
});

</pre>


All this processing is handled in an async manner and back pressure is applied. So stay tuned for more news on Reactive Streams, exciting times ahead.

# So what ?
Being part of such a movement is a big honour for me and I am looking forward to help shape the future of asynchronous processing. Special thanks to [Typesafe](https://www.typesafe.com) for driving the effort at the first place and [Red Hat](http://www.redhat.com) for allowing me to spend time on it.


