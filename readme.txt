# a bluetooth plugin

this plugin only deals with turning bluetooth on and off for my use.

you need to commentout the killing of bluetoothd on power up.

Also near the fake_events input, open up the event that your bluetooth device maps to. my device requires uhid.ko patch to installed before the event pops up as /dev/input/event3

and then you need to define the action and what it does. 

It's all discussed here:
https://github.com/koreader/koreader/issues/9059

I may make it into a more concise doucment/plugin if there's interest. 
