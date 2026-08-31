# DIPx controller project

Embedded into the lean STOKER controller ISO. The first boot runs `deploy.yml` locally to stage `govc` and mark the controller ready for later DIPx host/VM orchestration.

This initial project deliberately does not persist ESXi credentials. A one-time credential handoff through VMware guestinfo is the preferred next step for fully autonomous API bootstrap.
