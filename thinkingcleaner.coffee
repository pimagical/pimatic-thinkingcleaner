module.exports = (env) ->

  Promise = env.require 'bluebird'
  assert = env.require 'cassert'

  request = require 'request'
  Promise.promisifyAll(request)

  class ThinkingCleanerPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass("ThinkingCleanerDevice", {
        configDef: deviceConfigDef.ThinkingCleanerDevice,
        createCallback: (config) -> new ThinkingCleanerDevice(config)
      })

      #wait till all plugins are loaded
      @framework.on "after init", =>
        # Check if the mobile-frontent was loaded and get a instance
        mobileFrontend = @framework.pluginManager.getPlugin 'mobile-frontend'
        if mobileFrontend?
          mobileFrontend.registerAssetFile 'js', "pimatic-thinkingcleaner/app/thinkingcleaner.coffee"
          mobileFrontend.registerAssetFile 'css', "pimatic-thinkingcleaner/app/css/thinkingcleaner.css"
          mobileFrontend.registerAssetFile 'html', "pimatic-thinkingcleaner/app/thinkingcleaner.html"
        else
          env.logger.warn "ThinkingCleaner could not find the mobile-frontend. No gui will be available"

  class ThinkingCleanerDevice extends env.devices.Device
    attributes:
      battery:
        description: "battery state"
        type: "number"
        discrete: true
        unit: "%"
      state:
        description: "state"
        type: "string"

    actions:
      sendCommand:
        params: 
          command: 
            type: "string"

    template: "ThinkingCleanerDevice"

    battery: 0
    state: "none"

    constructor: (@config) ->
      @id = @config.id
      @name = @config.name
      @host = @config.host
      @interval = @config.interval
      super()
      @readLoop    

    readLoop: =>
      setInterval( =>
        request 'http://"+@host+"/status.json', (error, response, body) =>
          if (!error && response.statusCode == 200)
            data = JSON.parse(body)
            @setState data.status.cleaner_state 
            @setBattery data.status.battery_charge
      , @interval)

    getBattery: () -> Promise.resolve(@battery)
    getState: () -> Promise.resolve(@state)

    setBattery: (battery) ->
      @battery = battery
      @emit "battery", @battery

    setState: (state) ->
      @state = state
      @emit "state", @state

    sendCommand: (command) ->
      request "http://"+@host+"/command.json?command="+command, (error, response, body) =>
        if (!error && response.statusCode == 200) 
          data = JSON.parse(body)

  class ThinkingCleanerModeActionProvider extends env.actions.ActionProvider

    constructor: (@framework) ->

    parseAction: (input, context) =>
      # The result the function will return:
      retVar = null

      tcleaners = _(@framework.deviceManager.devices).values().filter( 
        (device) => device.hasAction("sendCommand") 
      ).value()

      if tcleaners.length is 0 then return

      device = null
      valueTokens = null
      match = null

      # Try to match the input string with:
      M(input, context)
        .match('set mode of ')
        .matchDevice(thermostats, (next, d) =>
          next.match(' to ')
            .matchStringWithVars( (next, ts) =>
              m = next.match(' mode', optional: yes)
              if device? and device.id isnt d.id
                context?.addError(""""#{input.trim()}" is ambiguous.""")
                return
              device = d
              valueTokens = ts
              match = m.getFullMatch()
            )
        )

      if match?
        if valueTokens.length is 1 and not isNaN(valueTokens[0])
          value = valueTokens[0] 
          assert(not isNaN(value))
          modes = ["clean", "max", "spot", "dock", "findme", "off"] 
          if modes.indexOf(value) < -1
            context?.addError("Allowed modes: clean, max, spot, dock, findme, off")
            return
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new ThinkingCleanerModeActionHandler(@framework, device, valueTokens)
        }
      else 
        return null

  class ThinkingCleanerModeActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @device, @valueTokens) ->
      assert @device?
      assert @valueTokens?

    _doExecuteAction: (simulate, value) =>
      return (
        if simulate
          __("would set mode %s to %s%%", @device.name, value)
        else
          @device.sendCommand(value).then( => __("set mode %s to %s%%", @device.name, value) )
      )

    executeAction: (simulate) => 
      @framework.variableManager.evaluateStringExpression(@valueTokens).then( (value) =>
        @lastValue = value
        return @_doExecuteAction(simulate, value)
      )

    hasRestoreAction: -> yes
    executeRestoreAction: (simulate) => Promise.resolve(@_doExecuteAction(simulate, @lastValue))

  thinkingCleanerPlugin = new ThinkingCleanerPlugin
  return thinkingCleanerPlugin
