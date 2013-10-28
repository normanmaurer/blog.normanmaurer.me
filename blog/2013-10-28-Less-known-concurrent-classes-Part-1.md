---
layout: post
title: 'Less known concurrent classes - Atomic*FieldUpdater'
author: normanmaurer
---

Today I want to talk about one of the less known utility classes when it comes to atomic operations in Java. Everyone who ever has done some real work with the java.util.concurrent package should be aware of the Atomic* classes in there which helps you to do atomic operations on references, Longs, Integers, Booleans and more.

The classes in question are all located in the [java.util.concurrent.atomic package](http://docs.oracle.com/javase/7/docs/api/java/util/concurrent/atomic/package-summary.html). Like:
 * `AtomicBoolean`
 * `AtomicInteger`
 * `AtomicReference`
 * `AtomicLong` 
 ....

Using those is as easy as doing something like:

    AtomicLong atomic = new AtomicLong(0);
    atomic.compareAndSet(0, 1);
    ...
    ...

So what is the big deal with them? It's about memory usage ... 
Wouldn't it be nice to be able to just use a `volatile long` and so use less heap space? 

> HELL YEAH!

This is exactly where the not widely known Atomic*FieldUpdater comes in. Those allow you to do atomic operations on a volatile field and so save the space which is needed to hold the object that you would create if you would use something like `AtomicLong`. This works as Atomic*FieldUpdater is used as a static field and so not need to create a new Object everytime.

> Neat, isn't it ?

So to replace the above usage of `AtomicLong` your code would look like:

        private static final AtomicLongFieldUpdater<TheDeclaringClass> ATOMIC_UPDATER =
            AtomicLongFieldUpdater.newUpdater(TheDeclaringClass.class, "atomic");

    private volatile long atomic;

    public void yourMethod() {
        ATOMIC_UPDATER.compareAndSet(this, 0, 1);
        ...
        ...
    }

This works with some reflection magic which is used when you create the `AtomicLongFieldUpdater` instance. The passed in fieldname (in this case atomic) will be used to lookup the declared volatile field. Thus you must be sure it matches. 
And this is one of the weak things when using Atomic*FieldUpdater as there is no way for the compiler to detect that those match. So you need to keep an eye on this by yourself. 

You may ask you self about if it worth it at all? As always it depends... If you only create a few thousands instances of the class that use Atomic* it may not worth it at all. But there may be situations where you need to create millions of them and keep the alive for a long time. In those situations it can have a big impact.

In the case of the [Netty Project](http://netty.io) we used `AtomicLong` and `AtomicReference` in our `Channel`, `DefaultChannelPipeline` and `DefaultChannelHandlerContext` classes. A new instance of `Channel` and `ChannelPipele` is created for each new Connection that is accepted or established and it is not unusal to have 10  (or more ) `DefaultChannelHandlerContext` objects per `DefaultChannelPipeline`. For Non-Blocking Servers it is not unusal to handle a very big amout of concurrent connections, which in our case was creating many instances of the mentioned classes. Those stayed alive for a long time as connections may be long-living. One of our users was testing 1M+ concurrent connections at this time and saw a big amount of heap space taken up because of the `AtomicLongi` and `AtomicReference` instances we were using. By replacing those with AtomicField*Updater we was able to save about 500M of memory which in combination with other changes made a difference of 3 GB less memory usage.

For more details on the specific issue please have a look at those two issues: [#920](https://github.com/netty/netty/issues/920) and [#995](https://github.com/netty/netty/issues/995)

On thing to note is that there is no `AtomicBooleanFieldUpdater` which you could use to replace `AtomicBoolean`. This is not a problem, just use `AtomicIntegerFieldUpdater` with value 0 as false and 1 as true. Problem solved ;)

## Gimme some numbers
So after all of this it would be nice to actual proof it. So let us do some simple test here. We create a Class which will contain 10 AtomicLong  and 10 AtomicReference instances and instance the class itself 1M times. This kind of mimic the pattern we saw within [Netty](http://netty.io).


Let us first have a look at the actual code:

    public class AtomicExample {

        final AtomicLong atomic1 = new AtomicLong(0);
        final AtomicLong atomic2 = new AtomicLong(0);
        final AtomicLong atomic3 = new AtomicLong(0);
        final AtomicLong atomic4 = new AtomicLong(0);
        final AtomicLong atomic5 = new AtomicLong(0);
        final AtomicLong atomic6 = new AtomicLong(0);
        final AtomicLong atomic7 = new AtomicLong(0);
        final AtomicLong atomic8 = new AtomicLong(0);
        final AtomicLong atomic9 = new AtomicLong(0);
        final AtomicLong atomic10 = new AtomicLong(0);
        final AtomicReference atomic11 = new AtomicReference<String>("String");
        final AtomicReference atomic12 = new AtomicReference<String>("String");
        final AtomicReference atomic13 = new AtomicReference<String>("String");
        final AtomicReference atomic14 = new AtomicReference<String>("String");
        final AtomicReference atomic15 = new AtomicReference<String>("String");
        final AtomicReference atomic16 = new AtomicReference<String>("String");
        final AtomicReference atomic17 = new AtomicReference<String>("String");
        final AtomicReference atomic18 = new AtomicReference<String>("String");
        final AtomicReference atomic19 = new AtomicReference<String>("String");
        final AtomicReference atomic20 = new AtomicReference<String>("String");

        public static void main(String[] args) throws Exception {
            List<AtomicExample> list = new LinkedList<AtomicExample>();
            for (int i = 0; i < 1000000; i++) {
                list.add(new AtomicExample());
            }
            System.out.println("Created instances 1000000");

            Thread.sleep(60 * 1000 * 60);
        }
    }

This code mimics the creation of 1M instances which each has 10 `AtomicLong` instances and 10 `AtomicReference` instances. You may thing this is not very often the case in real world applications but just think about it for a bit. It may not be in one class but actually may be in many classes but which are still related. Like all of them are created for each new connection.

Now let us have a look at how much memory is retained by them. For this I used Yourkit but any other tool which can inspect heap-dumps should just work fine.

![AtomicExample](/blog/images/AtomicExample.png "Memory usage of AtomicExample")

As you can see AtomicLong and AtomicReference took about about 400MB of memory where AtomicExample itself takes up 96MB. This makes up a a sum of ca. 500MB memory that is used by each AtomicExample instance that is created.

Now let us do a second version of this class but replace `AtomicLong` with `volatile long` and `AtomicLongFieldUpdater`. Beside this we also replace `AtomicReference` with `volatile String` and `AtomicReferenceFieldUpdater`.

The code looks like this now:

    public class AtomicFieldExample {

        volatile long atomic1 = 0;
        volatile long atomic2 = 0;
        volatile long atomic3 = 0;
        volatile long atomic4 = 0;
        volatile long atomic5 = 0;
        volatile long atomic6 = 0;
        volatile long atomic7 = 0;
        volatile long atomic8 = 0;
        volatile long atomic9 = 0;
        volatile long atomic10 = 0;
        volatile String atomic11 = "String";
        volatile String atomic12 = "String";
        volatile String atomic13 = "String";
        volatile String atomic14 = "String";
        volatile String atomic15 = "String";
        volatile String atomic16 = "String";
        volatile String atomic17 = "String";
        volatile String atomic18 = "String";
        volatile String atomic19 = "String";
        volatile String atomic20 = "String";

        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC1_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic1");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC2_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic2");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC3_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic3");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC4_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic4");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC5_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic5");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC6_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic6");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC7_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic7");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC8_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic8");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC9_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic9");
        static final AtomicLongFieldUpdater<AtomicFieldExample> ATOMIC10_UPDATER = 
                AtomicLongFieldUpdater.newUpdater(AtomicFieldExample.class, "atomic10");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC11_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic11");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC12_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic12");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC13_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic13");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC14_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic14");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC15_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic15");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC16_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic16");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC17_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic17");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC18_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic18");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC19_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic19");
        static final AtomicReferenceFieldUpdater<AtomicFieldExample, String> ATOMIC20_UPDATER = 
                AtomicReferenceFieldUpdater.newUpdater(AtomicFieldExample.class, String.class, "atomic20");

        public static void main(String[] args) throws Exception {
            List<AtomicFieldExample> list = new LinkedList<AtomicFieldExample>();
            for (int i = 0; i < 1000000; i++) {
                list.add(new AtomicFieldExample());
            }
            System.out.println("Created instances 1000000");

            Thread.sleep(60 * 1000 * 60);
        }
    }

As you see the code becomes a bit more bloaded, hopefully it pays out. Again let us take a look at the memory usage as before.


![AtomicFieldExample](/blog/images/AtomicFieldExample.png "Memory usage of AtomicFieldExample")

As you can see from the screenshot the used memory is a lot smaller. In fact it now needs not more then ca. 136MB of memory for the 1M instances of the `AtomicFieldExample`. This is a nice improvement compared to the previous memory usage. Now think about how much memory you can save if you have a few cases where you can replace Atomic* classes with volatile and Atomic*FieldUpdater in classes that are instanced a lot.

But it's not the whole story, as this does not contain the memory wasted because of all the referenced structs and orginating struct. How much is used exactly depends, but most of the times it's 4 bytes with compressed Ops enabled (which is the default). But on a 64-Bit system the cost can be up to 8 bytes per reference. 
