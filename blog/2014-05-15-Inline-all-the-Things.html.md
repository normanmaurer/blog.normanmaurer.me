---
layout: post
title: 'Inline all the Things'
author: normanmaurer
---

If you are familiar with the JVM or JIT you may know that there is a little magic happen that is called inlining. Inlining is often mention as one of the most powerful things the JIT can do to optimize your code while it is executed it at the same time.

#### But what is inlining and why the heck does it make things faster?

Inlining is a technique that will basically just "inline" one method in another and so get rid of a method invocation. The JIT automatically detects "hot" methods and try to inline them for you. A method is considered "hot" if it was executed more the X times, where X is a threshold that can be configured using a JVM flag when start up java (10000 is the default). This is needed as inlining all methods would do more harm then anything else, because of the enormous produced byte-code. Beside this the JIT may "revert" previous inlined code when an optimization turns out to be wrong at a later state. Remember the JIT stands for Just in Time and so optimize (which includes inlining but also other things) while execute your code.

But even if the JVM consider a method to be "hot" it may not inline it. But why? One of the most likely reasons is that it is just to big to get inlined.
How big a hot method can be and still be inlined is defined via the `-XX:FreqInlineSize=` and is 325 bytecode instructions as default on Linux 64 Bit. The default value is platform dependent. Don't change this number if you are not 100% sure you understand what you are doing and the impact of it!

So this gives us the first advice:

 __The JVM loves small methods__

So if your method is hot but is to big you should think about how you can make it smaller.

Now you may wonder yourself how to find out about what is inlined and what not. Fortunally it's quite easy to gather this informations. All you need is some extra JVM flags during startup. Those are:

* -XX:+PrintCompilation: Prints out when JIT compilation happens
* -XX:+UnlockDiagnosticVMOptions: Is needed to use flags like -XX:+PrintInlining
* -XX:+PrintInlining: Prints what methods were inlined

That's it. With those flags you will get a lot of informations logged to STDOUT, so you should store them in a log file to better analyze later.
So with this background let us focus on how you can make the best use out of it.

#### Optimize performance by allow for inline - A real story 

As most of you may know I'm working on the [Netty Project](http://netty.io) as part of my day job. Netty tries to make development of asynchronous network applications easy while still provide an excellent performance. So I often end up running benchmarks as part of my work, which was exactly what I did when came across the "problem". 

While doing the benchmark I started to wonder how well the JIT kicks in when Netty is used as simple HTTP Server. So I fired up the [Hello World HTTP Server example](https://github.com/netty/netty/tree/master/example/src/main/java/io/netty/example/http/helloworld) with the previous mention JVM args like:

    java -XX:+PrintCompilation -XX:+UnlockDiagnosticVMOptions -XX:+PrintInlining .... > inline.log

Now it was time to generate some workload on the HTTP Server so it does some real-world. For this I used one of my prefered benchmarking tools when it comes to HTTP, [wrk](https://github.com/netty/wrk/wrk/).

    wrk -H 'Host: localhost' -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' -H 'Connection: keep-alive' -d 600 -c 1024 -t 8 http://127.0.0.1:8080/plaintext

This basically runs the test for 10 minutes with 1024 concurrent clients. Sending a simple GET request and wait for a response. Nothing fancy here, so moving on ;)

After this completed I was about to review the inline.log file. Like I said before the output is really noise and looks like:

     66527  370             io.netty.channel.nio.NioEventLoop::processSelectedKeysOptimized (80 bytes)
                            @ 14   java.nio.channels.SelectionKey::attachment (5 bytes)   inline (hot)
               !            @ 33   io.netty.channel.nio.NioEventLoop::processSelectedKey (120 bytes)   inline (hot)
                              @ 1   io.netty.channel.nio.AbstractNioChannel::unsafe (8 bytes)   inline (hot)
                                @ 1   io.netty.channel.AbstractChannel::unsafe (5 bytes)   inline (hot)
                              @ 6   java.nio.channels.spi.AbstractSelectionKey::isValid (5 bytes)   inline (hot)
                              @ 26   sun.nio.ch.SelectionKeyImpl::readyOps (9 bytes)   inline (hot)
                                @ 1   sun.nio.ch.SelectionKeyImpl::ensureValid (16 bytes)   inline (hot)
                                  @ 1   java.nio.channels.spi.AbstractSelectionKey::isValid (5 bytes)   inline (hot)
               !              @ 42   io.netty.channel.nio.AbstractNioByteChannel$NioByteUnsafe::read (191 bytes)   inline (hot)
               !              @ 42   io.netty.channel.nio.AbstractNioMessageChannel$NioMessageUnsafe::read (327 bytes)   hot method too big
                                @ 4   io.netty.channel.socket.nio.NioSocketChannel::config (5 bytes)   inline (hot)
                                  @ 1   io.netty.channel.socket.nio.NioSocketChannel::config (5 bytes)   inline (hot)
                                @ 12   io.netty.channel.AbstractChannel::pipeline (5 bytes)   inline (hot)
                                @ 17   io.netty.channel.DefaultChannelConfig::getAllocator (5 bytes)   inline (hot)
                                @ 24   io.netty.channel.DefaultChannelConfig::getMaxMessagesPerRead (5 bytes)   inline (hot)
                                @ 44   io.netty.channel.DefaultChannelConfig::getRecvByteBufAllocator (5 bytes)   inline (hot)
                                @ 49   io.netty.channel.AdaptiveRecvByteBufAllocator::newHandle (20 bytes)   executed < MinInlining Threshold times

The most interesting things here are method which are marked as "hot method too big". Those are the methods which the JIT consider to be hot (so executed a lot) but are to big to consider them for inlining at all. If you want to archive max speed you don't want to see this ;) Or at least you want to try to make them shorter.

But how to shorten them without loosing functionality? The solution is to move "less common patterns" out of the method into another method. This way the method itself becomes smaller while still be able to cover everything by the cost of dispatch to another method. This is exactly what I did for the here is what it looks like for the io.netty.channel.nio.AbstractNioMessageChannel$NioMessageUnsafe::read method. 

Before optimize it it looked like:

<pre class="syntax java">
    private final class NioMessageUnsafe extends AbstractNioUnsafe {
    	...

        @Override
        public void read() {
            assert eventLoop().inEventLoop();
            final SelectionKey key = selectionKey();
            if (!config().isAutoRead()) {
                int interestOps = key.interestOps();
                if ((interestOps & readInterestOp) != 0) {
                    // only remove readInterestOp if needed
                    key.interestOps(interestOps & ~readInterestOp);
                }
            }

            final ChannelConfig config = config();
            final int maxMessagesPerRead = config.getMaxMessagesPerRead();
            final boolean autoRead = config.isAutoRead();
            final ChannelPipeline pipeline = pipeline();
            boolean closed = false;
            Throwable exception = null;
            try {
                for (;;) {
                    int localRead = doReadMessages(readBuf);
                    if (localRead == 0) {
                        break;
                    }
                    if (localRead < 0) {
                        closed = true;
                        break;
                    }

                    if (readBuf.size() >= maxMessagesPerRead | !autoRead) {
                        break;
                    }
                }
            } catch (Throwable t) {
                exception = t;
            }

            int size = readBuf.size();
            for (int i = 0; i < size; i ++) {
                pipeline.fireChannelRead(readBuf.get(i));
            }
            readBuf.clear();
            pipeline.fireChannelReadComplete();

            if (exception != null) {
                if (exception instanceof IOException) {
                    // ServerChannel should not be closed even on IOException because it can often continue
                    // accepting incoming connections. (e.g. too many open files)
                    closed = !(AbstractNioMessageChannel.this instanceof ServerChannel);
                }

                pipeline.fireExceptionCaught(exception);
            }

            if (closed) {
                if (isOpen()) {
                    close(voidPromise());
                }
            }
        }
        ...
    }
</pre>
What the method does is to read messages and the pass them through a pipeline for further processing. But how to make the method smaller without loose functionality? The key here is that the method checks on every execution if `isAutoRead() == false` and if not remove the interest ops from the SelectionKey. But the default is `true` and will never be `false` and almost noone will ever cheange this behavior (as it's for advanced usage only). So why not move the code out there, as we only need to save a few bytes...

So here we go:

<pre class="syntax java">
    private final class NioMessageUnsafe extends AbstractNioUnsafe {
        ...

        private void removeReadOp() {
            SelectionKey key = selectionKey();
            int interestOps = key.interestOps();
            if ((interestOps & readInterestOp) != 0) {
                // only remove readInterestOp if needed
                key.interestOps(interestOps & ~readInterestOp);
            }
        }
    
        @Override
        public void read() {
            assert eventLoop().inEventLoop();
            if (!config().isAutoRead()) {
                removeReadOp();
            }

            final ChannelConfig config = config();
            ...
        }
        ...
    }
</pre>

You see I just moved everything to the new method called `removeReadOp`. Now running the application again and re-run the same test as before the JIT was able to finally inline it. 

                   !              @ 42   io.netty.channel.nio.AbstractNioMessageChannel$NioMessageUnsafe::read (288 bytes)   inline (hot)

This eliminates the overhead of an method invocation / dispatch and so makes the execution of the code faster. You can find the full issue details in [issue #1812](https://github.com/netty/netty/issues/1812). 


#### Make JIT's job easier

Beside have small methods there are other things you can do the help the JIT to inline methods. Inlining of methods is a lot "easier" by:

 * Use private methods when possible, as this way there is no need to check for other classes that override those methods
 * Use final classes / methods for the same reason as stated above
 * Use static methods for the same reason as stated above.

It's also fair to say that have a "flat" class hierarchy helps a lot. The JVM / JIT does especially handle situations very well when you have only two implementations of a specific interface or abstract base class. This is because it can handle things quite easy with an almost free instanceof check. For more informations on this topic please check [Cliff Clicks post](http://www.cliffc.org/blog/2007/11/06/clone-or-not-clone/).


#### Inline != Inline

Even if a method is inlined it may not perform as well as another inlined method. Why is that? Basically it makes a difference if a protected/public method is inlined or a private/static one. This is because even if a protected / public method is inlined it still needs to do type-checks to be safe, as another class may be loaded that override/implement those. This is not the case for private / static methods, as the JVM / JIT knows here that those will always be the same.

So in some situations it may pay off to just "copy" code and not use abstract / protected / public etc to share it. __But__ always think about the tradeoffs, which are mainly caused by maintance hell. So only do it if you really need to. As always meassure it, and see if you need the last 2% performance. So don't say I haven't warned you ;)

#### Summary

So does it worth all the effort? As always it depends...  But if you are sure the hot-method is the one for the common use-pattern and you can split it up to move the "non-common" path out of the method and not make it complex as hell, YES it worth it.



