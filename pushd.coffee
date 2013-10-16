settings = require './settings'

# modules
express = require 'express'
dgram = require 'dgram'
zlib = require 'zlib'
url = require 'url'
logger = require 'winston'
Netmask = require('netmask').Netmask

# db
switch settings.server.active_db
    when 'redis'
        dbInstance = require('redis').createClient(settings.server.redis_socket or settings.server.redis_port, settings.server.redis_host)
        if settings.server.redis_auth?
            dbInstance.auth(settings.server.redis_auth)
    else throw new Error("`active_db` is not set")

# db models
Subscriber = require("./lib/models/#{settings.server.active_db}/subscriber").Subscriber
Event = require("./lib/models/#{settings.server.active_db}/event").Event

# other
EventPublisher = require('./lib/eventpublisher').EventPublisher
PushServices = require('./lib/pushservices').PushServices
Payload = require('./lib/payload').Payload


if settings.loglevel?
    logger.remove(logger.transports.Console);
    logger.add(logger.transports.Console, { level: settings.loglevel });

createSubscriber = (fields, cb) ->
    logger.verbose "creating subscriber proto = #{fields.proto}, token = #{fields.token}"
    throw new Error("Invalid value for `proto'") unless service = pushServices.getService(fields.proto)
    throw new Error("Invalid value for `token'") unless fields.token = service.validateToken(fields.token)
    Subscriber::create(dbInstance, fields, cb)

tokenResolver = (proto, token, cb) ->
    Subscriber::getInstanceFromToken dbInstance, proto, token, cb

eventSourceEnabled = no
pushServices = new PushServices()
for name, conf of settings when conf.enabled
    logger.info "Registering push service: #{name}"
    if name is 'event-source'
        # special case for EventSource which isn't a pluggable push protocol
        eventSourceEnabled = yes
    else
        pushServices.addService(name, new conf.class(conf, logger, tokenResolver))
eventPublisher = new EventPublisher(pushServices)

checkUserAndPassword = (username, password) =>
    if settings.server?.auth?
        if not settings.server.auth[username]?
            logger.error "Unknown user #{username}"
            return false
        passwordOK = password is settings.server.auth[username].password
        if not passwordOK
            logger.error "Invalid password for #{username}"
        return passwordOK
    return false

app = express()

app.configure ->
    app.use(express.logger(':method :url :status')) if settings.server?.access_log
    app.use(express.limit('1mb')) # limit posted data to 1MB
    if settings.server?.auth? and not settings.server?.acl?
        app.use(express.basicAuth checkUserAndPassword)
    app.use(express.bodyParser())
    app.use(app.router)
    app.disable('x-powered-by');

app.param 'subscriber_id', (req, res, next, id) ->
    try
        req.subscriber = new Subscriber(dbInstance, req.params.subscriber_id)
        delete req.params.subscriber_id
        next()
    catch error
        res.json error: error.message, 400

getEventFromId = (id) ->
    return new Event(dbInstance, id)

testSubscriber = (subscriber) ->
    pushServices.push(subscriber, null, new Payload({msg: "Test", "data.test": "ok"}))

app.param 'event_id', (req, res, next, id) ->
    try
        req.event = getEventFromId(req.params.event_id)
        delete req.params.event_id
        next()
    catch error
        res.json error: error.message, 400

authorize = (realm) ->
    if settings.server?.auth?
        return (req, res, next) ->
            # req.user has been set by express.basicAuth
            logger.verbose "Authenticating #{req.user} for #{realm}"
            if not req.user?
                logger.error "User not authenticated"
                res.json error: 'Unauthorized', 403
                return

            allowedRealms = settings.server.auth[req.user]?.realms or []
            if realm not in allowedRealms
                logger.error "No access to #{realm} for #{req.user}, allowed: #{allowedRealms}"
                res.json error: 'Unauthorized', 403
                return

            next()
    else if allow_from = settings.server?.acl?[realm]
        networks = []
        for network in allow_from
            networks.push new Netmask(network)
        return (req, res, next) ->
            if remoteAddr = req.socket and (req.socket.remoteAddress or (req.socket.socket and req.socket.socket.remoteAddress))
                for network in networks
                    if network.contains(remoteAddr)
                        next()
                        return
            res.json error: 'Unauthorized', 403
    else
        return (req, res, next) -> next()

require('./lib/api').setupRestApi(app, createSubscriber, getEventFromId, authorize, testSubscriber, eventPublisher)
if eventSourceEnabled
    require('./lib/eventsource').setup(app, authorize, eventPublisher)

port = settings?.server?.tcp_port ? 80
app.listen port
logger.info "Listening on tcp port #{port}"


# UDP Event API
udpApi = dgram.createSocket("udp4")

event_route = /^\/event\/([a-zA-Z0-9:._-]{1,100})$/
udpApi.checkaccess = authorize('publish')
udpApi.on 'message', (msg, rinfo) ->
    zlib.unzip msg, (err, msg) =>
        if err or not msg.toString()
            logger.error("UDP Cannot decode message: #{err}")
            return
        [method, msg] = msg.toString().split(/\s+/, 2)
        if not msg then [msg, method] = [method, 'POST']
        req = url.parse(msg ? '', true)
        method = method.toUpperCase()
        # emulate an express route middleware call
        @checkaccess {socket: remoteAddress: rinfo.address}, {json: -> logger.info("UDP/#{method} #{req.pathname} 403")}, ->
            status = 404
            if m = req.pathname?.match(event_route)
                try
                    event = new Event(dbInstance, m[1])
                    status = 204
                    switch method
                        when 'POST' then eventPublisher.publish(event, req.query)
                        when 'DELETE' then event.delete()
                        else status = 404
                catch error
                    logger.error(error.stack)
                    return
            logger.info("UDP/#{method} #{req.pathname} #{status}") if settings.server?.access_log

port = settings?.server?.udp_port
if port?
    udpApi.bind port
    logger.info "Listening on udp port #{port}"
