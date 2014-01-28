settings = require '../settings'
process = require('process')

# db models
Event = require("../lib/models/#{settings.server.active_db}/event").Event
dbInstance = require('redis').createClient(settings.server.redis_socket or settings.server.redis_port, settings.server.redis_host)

if settings.server.redis_auth?
    dbInstance.auth(settings.server.redis_auth)

class SubscribersCommand

    availableActions = ['subscribe', 'unsubscribe']
    action = ''
    event_from = ''
    event_to = ''

    constructor: (@dbInstance, Event, @process) ->
        if !@process.argv[2] or @process.argv[2] not in availableActions
            @invalidArguments()

        @action = @process.argv[2]
        @event_from = @process.argv[3]
        @event_to = @process.argv[4]

        switch action
            when 'subscribe'
                if !@process.argv[3] or !@process.argv[4] 
                    @invalidArguments()
            when 'unsubscribe'
                if !@process.argv[3]
                    @invalidArguments()

    run: ->
        eventFrom = new Event(@dbInstance, @event_from)
        eventTo = new Event(@dbInstance, @event_to)

        eventFrom.exists (isExist) =>
            if isExist then @updateSubscribers(eventFrom, eventTo) else @noEvent(@event_from)

    invalidArguments: ->
        console.log "You should pass two arguments, like this:\n"
        , "coffee subscribers <#{availableActions}> <event_from> [event_to]"
        @process.exit()


    onEnd: ->
        @dbInstance.end()

    updateSubscribers: (eventFrom, eventTo) ->
        eventFrom.forEachSubscribers (subscriber, options, done) =>
            switch @action
                when 'subscribe'
                    subscriber.addSubscription eventTo, 0, () -> done()
                when 'unsubscribe'
                    subscriber.removeSubscription eventFrom, () -> done()
            @process.stdout.write '.'
        , (countTotal) =>
            console.log "\ntotal: #{countTotal}"
            @onEnd()

    noEvent: (name) ->
        console.log "Event '#{name}' does not exist"
        @onEnd()

instance = new SubscribersCommand dbInstance, Event, process
instance.run()
