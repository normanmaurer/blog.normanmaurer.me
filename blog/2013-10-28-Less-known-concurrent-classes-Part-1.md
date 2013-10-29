---
layout: post
title: 'Less known concurrent classes - Atomic*FieldUpdater'
author: normanmaurer
---

Today I want to talk about one of the lesser known utility classes when it comes to atomic operations in Java. Everyone who has ever done some real work with the `java.util.concurrent` package should be aware of the Atomic* classes which help you to do atomic operations on references, Longs, Integers, Booleans and more.

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
Wouldn't it be nice to be able to just use a `volatile long`, save a object allocation and as a result use less heap space? 

> HELL YEAH!

This is exactly where the not widely known `Atomic*FieldUpdater` classes come in. They allow you to do atomic operations on volatile fields and as a result prevent you from unecessary object allocations (for example of an `AtomicLong`).

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

This works with some reflection magic which is used when you create the `AtomicLongFieldUpdater` instance. The passed in fieldname (in this case "atomic") will be used to lookup the declared volatile field. Thus you must be sure it matches exactly. As you can imagine, this is one of the weak things when using the Atomic*FieldUpdater as there is no way for the compiler to detect that those match. So you need to keep an eye on this by yourself. 

You may ask yourself if this pays off at all. As always it depends... If you only create a few thousands instances of the class that use Atomic* it may not worth the additional effort. But there may be situations where you need to create millions of them and keep the alive for a long time. In those situations it can have a big impact.

In the case of the [Netty Project](http://netty.io) we used `AtomicLong` and `AtomicReference` in our `Channel`, `DefaultChannelPipeline` and `DefaultChannelHandlerContext` classes. A new instance of `Channel` and `ChannelPipeline` is created for each new connection that is accepted or established and it is not unusal to have 10  (or more) `DefaultChannelHandlerContext` objects per `DefaultChannelPipeline`. For non-blocking servers it is not unusual to handle a very big amout of concurrent connections, which in our case was creating many instances of the mentioned classes. Those stayed alive for a long time as connections may be long-lived. One of our users was testing 1M+ concurrent connections at this time and saw a big amount of heap space taken up because of the `AtomicLong` and `AtomicReference` instances we were using. By replacing those with AtomicField*Updater we were able to save about 500 megabytes of memory which in combination with other changes resulted in 3 gigabytes less memory usage.

For more details on the specific enhancements please have a look at those two issues: [#920](https://github.com/netty/netty/issues/920) and [#995](https://github.com/netty/netty/issues/995)

On thing to note is that there is no `AtomicBooleanFieldUpdater` which you could use to replace a `AtomicBoolean`. This is not a problem, just use `AtomicIntegerFieldUpdater` with value 0 as false and 1 as true. Problem solved ;)

## Gimme some numbers
Now with some theory behind us, let's proof our claim. So let's do some simple test here: we create a class which will contain 10 `AtomicLong` and 10 `AtomicReference` instances and instantiate the class itself 1M times. This resembles the pattern we saw with [Netty](http://netty.io).

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
            int instances = 1000000;
            for (int i = 0; i < instances; i++) {
                list.add(new AtomicExample());
            }
            System.out.println("Created " + instances + "instances");

            Thread.sleep(TimeUnit.HOURS.toMillis(1));
        }
    }

You may think this is not very often the case in real world applications but just think about it for a bit. It may not be in one class but actually may be in many classes but which are still related. Like all of them are created for each new connection.

Now let us have a look at how much memory is retained by them. For this I used [YourKit](http://www.yourkit.com/) but any other tool which can inspect heap-dumps should just works fine.

![AtomicExample](/blog/images/AtomicExample.png "Memory usage of AtomicExample")

As you can see AtomicLong and AtomicReference instances together use about 400MB of memory where AtomicExample itself takes up 96MB.

Now let's do a second version of this class but replace `AtomicLong` with `volatile long` and `AtomicLongFieldUpdater`. Beside this we also replace `AtomicReference` with `volatile String` and `AtomicReferenceFieldUpdater`.

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
            int instances = 1000000;
            for (int i = 0; i < instances; i++) {
                list.add(new AtomicFieldExample());
            }
            System.out.println("Created " + instances + "instances");

            Thread.sleep(TimeUnit.HOURS.toMillis(1));
        }
    }

As you see the code becomes a bit more bloated, but hopefully it pays off. Again, let's take a look at the memory usage as before.

![AtomicFieldExample](/blog/images/AtomicFieldExample.png "Memory usage of AtomicFieldExample")

As you can see from the screenshot the used memory is a lot smaller. In fact it now needs not more then ca. 136MB of memory for the 1M instances of the `AtomicFieldExample`. This is a nice improvement compared to the previous memory usage. Now think about how much memory you can save if you have a few cases where you can replace Atomic* classes with volatile and Atomic*FieldUpdater in classes that are instanced a lot.

But it's not the whole story, as this does not contain the memory wasted because of all the referenced structs and orginating struct. How much is used exactly depends, but most of the times it's 4 bytes with compressed Ops enabled (which is the default). But on a 64-Bit system the cost can be up to 8 bytes per reference. 
