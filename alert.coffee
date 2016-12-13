module.exports = (env) =>

  Promise = env.require 'bluebird'
  t = env.require('decl-api').types
  _ = env.require 'lodash'


  class AlertPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      env.logger.info "Starting alert system ..."

      @_afterInit = false

      deviceConfigDef = require('./device-config-schema.coffee')

      @framework.deviceManager.registerDeviceClass 'AlertSwitch',
        configDef: deviceConfigDef.AlertSwitch
        createCallback: (config, lastState) ->
          return new AlertSwitch(config, lastState)

      @framework.deviceManager.registerDeviceClass 'AlertSystem',
        configDef: deviceConfigDef.AlertSystem
        createCallback: (config, lastState) =>
          return new AlertSystem(config, lastState, @)

      @framework.on 'after init', =>
        @_afterInit = true

    afterInit: () =>
      return @_afterInit

  plugin = new AlertPlugin


  class AlertSwitch extends env.devices.DummySwitch


  class AlertSystem extends env.devices.DummySwitch

    _trigger: ""

    attributes:
      trigger:
        description: "Device that triggered the alarm"
        type: t.string
      state:
        description: "The current state of the switch"
        type: t.boolean
        labels: ['on', 'off']

    getTrigger: () -> Promise.resolve(@_trigger)

    _setTrigger: (trigger) ->
      @_trigger = if trigger? then @_trigger = trigger else @_trigger = ""
      @emit 'trigger', @_trigger if @displayTrigger


    constructor: (config, lastState, plugin) ->

      super(config, lastState)
      @config = config
      @plugin = plugin

      @deviceManager = @plugin.framework.deviceManager
      @variableManager = @plugin.framework.variableManager

      @timeformat = @plugin.config.timeformat
      @displayTrigger = @config.trigger
      @autoConfig = @config.autoconfig

      @sensors = null
      @switches = null
      @alert = null
      @remote = null
      @rejected = false

      @variables = {
        time: null    # timestamp of the last update
        info: null   # Enabled,Disabled,Rejected,Alert,Error
        state: null   # Enabled,Disabled,Rejected,Alert,Error
        trigger: null # device id of alert trigger
        reject: null  # device id which caused the reject
        error: null   # error message
      }


      @on 'rejected', () =>
        # switch back to "off" immediately after we resolved the state change
        env.logger.debug("Alert system \"#{@id}\" activation rejected")
        @getState().then( (state) => @changeStateTo(false) )

      @on 'state', (state) =>
        # process system switch state changes
        return unless @plugin.afterInit()
        # sync with optional remote switch
        @remote.changeStateTo(state) if @remote?
        if state
          if not @_checkSensors()
            @variables['state'] = "Rejected"
            @rejected = true
            @emit 'rejected'
          else
            @rejected = false
            @variables['state'] = "Enabled"
            @variables['trigger'] = null
            env.logger.debug("Alert system \"#{@id}\" enabled")
        else
          if not @rejected
            @variables['state'] = "Disabled"
            @variables['trigger'] = null
            # always switch off alert if system is disabled
            if @switches?
              @alert?.changeStateTo(state)
              for actuator in @switches
                actuator?.changeStateTo(state)
            @_setTrigger("")
            env.logger.debug("Alert system \"#{@id}\" disabled")

        @_updateState('state')

      @plugin.framework.on 'after init', =>
        # wait for the 'after init' event
        # until all devices are loaded
        @_initDevice('after init')

      if @plugin.afterInit()
        # initialize only on recreation of the device
        # skip if we are called the first time during
        # startup
        @_initDevice('constructor')
      else
        # autoconfiguration of option is set
        @_autoConfig() if @config.autoconfig

    destroy: () ->
      # remove event handlers from sensor devices
      env.logger.debug("Destroying alert system \"#{@id}\"")
      if @alert?
        @alert.removeListener 'state', alertHandler
        delete(@alert.system)
      if @remote?
        @remote.removeListener 'state', alertHandler
        delete(@remote.system)
      if @sensors?
        for sensor in @sensors
          delete(sensor.system)
          delete(sensor.required)
          delete(sensor.expectedValue)
          if sensor instanceof env.devices.PresenceSensor
            sensor.removeListener 'presence', sensorHandler
          else if sensor instanceof env.devices.ContactSensor
            sensor.removeListener 'contact', sensorHandler
          else
            env.logger.error("Invalid sensor type found in alert system \"#{@id}\"")
      super()

    setAlert: (device, alert) =>
      # called indirect by sensor devices via event handler
      # and from alert system device to switch off the alert
      if @_state
        if alert
          if device not instanceof env.devices.SwitchActuator
            env.logger.info("Alert triggered by \"#{device.id}\"")
            @variables['state'] = 'Alert'
            @variables['trigger'] = device.id
            @_updateState('alert')
            @_setTrigger(device.id)
        else
          env.logger.info("Alert switched off")
          @variables['state'] = 'Disabled'
          @_setTrigger(null)

        for actuator in @switches
          actuator.changeStateTo(alert)

    ################################################
    #  named removeable(!) alert handlers required #
    #  because auf device recreation               #
    ################################################

    alertHandler = (state) ->
      @system.setAlert(this, state)

    remoteHandler = (state) ->
      @system.changeStateTo(state)

    sensorHandler = (value) ->
      if value is @expectedValue
        @system.setAlert(this, true)

    ###############################################
    # delayed device initialization after startup #
    ###############################################

    _initDevice: (event) =>

      env.logger.debug("Initializing alert system \"#{@id}\" from [#{event}]")

      @sensors = []
      @switches = []
      @alert = null
      @remote = null

      @variables['state'] = "Error"

      if not @config.alert?
        env.logger.error("Missing alert switch in configuration for \"#{@id}\"")
        return
      alert = @deviceManager.getDeviceById(@config.alert)
      if alert not instanceof AlertSwitch
        env.logger.error("Device \"#{alert.id}\" is not a valid alert switch for \"#{@id}\"")
        return

      alert.system = @
      alert.on 'state', alertHandler

      @alert = alert
      @switches.push(alert)

      env.logger.debug("Device \"#{alert.id}\" registered as alert switch device for \"#{@id}\"")

      if @config.remote?
        remote = @deviceManager.getDeviceById(@config.remote)
        if remote?
          @remote = remote
          env.logger.debug("Device \"#{remote.id}\" registered as remote device for \"#{@id}\"")

          remote.system = @
          remote.on 'state', remoteHandler

      register = (sensor, event, expectedValue, required) =>
        env.logger.debug("Device \"#{sensor.id}\" registered as sensor for \"#{@id}\"")
        @sensors.push(sensor)

        sensor.system = @
        sensor.required = if required? then '_' + event else null
        sensor.expectedValue = expectedValue
        sensor.on event, sensorHandler

      for item in @config.sensors
        sensor = @deviceManager.getDeviceById(item.name)
        if sensor?
          if sensor instanceof env.devices.PresenceSensor
            register sensor, 'presence', true, item.required
          else if sensor instanceof env.devices.ContactSensor
            register sensor, 'contact', false, item.required
          else
            env.logger.error("Device \"#{sensor.id}\" is not a valid sensor for \"#{@id}\"")
        else
          env.logger.error("Device \"#{id}\" not found for \"#{@id}\"")

      for id in @config.switches
        actuator = @deviceManager.getDeviceById(id)
        if actuator?
          if actuator instanceof env.devices.SwitchActuator
            @switches.push(actuator)
            env.logger.debug("Device \"#{actuator.id}\" registerd as switch for \"#{@id}\"")
          else
            env.logger.error("Device \"#{actuator.id}\" is not a valid switch for \"#{@id}\"")

      @variables['state'] = if @_state then "Enabled" else "Disabled"
      @_updateState('init')

    _checkSensors: () =>
      for sensor in @sensors
        if sensor.required?
          if sensor[sensor.required] == sensor.expectedValue
            @variables['reject'] = sensor.id
            env.logger.info("Device #{sensor.id} not ready for alert system \"#{@id}\"")
            return false
      @variables['reject'] = null
      return true

    #####################################################
    # dynamic creation of devices and runtime vatiabled #
    #####################################################

    _autoConfig: () =>

      # AlertSwitch device
      alertId = if @config.alert? not '' then @config.alert else @id + '-switch'
      @config.alert = alertId
      if not @deviceManager.isDeviceInConfig(alertId)
        config = {
          id: alertId
          name: "#{@name} switch"
          class: "AlertSwitch"
        }
        try
          alert = @deviceManager._loadDevice(config, null, null)
          @deviceManager.addDeviceToConfig(config)
          env.logger.debug("Device \"#{alertId}\" added to configuration of \"#{@id}\"")
        catch error
          env.logger.error(error)

      # AlertSystem variable device setup
      variables = []
      for suffix, value of @variables
        name = @id + '-' + suffix
        if not @variableManager.isVariableDefined(name)
          @variableManager.addVariable(name, "value", "")

        variables.push({
          name: name
          expression: '$' + name
        }) if suffix in ["time", "info", "state"]

      variablesId = if @config.variables? not '' then @config.variables else @id + '-state'
      @config.state = variablesId
      if not @deviceManager.isDeviceInConfig(variablesId)
        config = {
          id: variablesId,
          name: "#{@name} state"
          class: "VariablesDevice"
          variables: variables
        }
        try
          state = @deviceManager._loadDevice(config, null, null)
          @deviceManager.addDeviceToConfig(config)
          env.logger.debug("Device \"#{variablesId}\" added to configuration of \"#{@id}\"")
        catch error
          env.logger.error(error)


    ################################################
    # update VariableDevice from runtime variables #
    ################################################

    _updateState: (reason) =>
    # display the state variables defined elsewhere
      @variables['time'] = new Date().format(@timeformat)
      _ = { "time": @variables['time'], "state": @variables['state'].toUpperCase() }

      trigger = @variables['trigger']
      reject = @variables['reject']
      error = @variables['error']

      _.info =
        if _.state is "ALERT" and trigger? then "[#{@deviceManager.getDeviceById(trigger).name}]"
        else if _.state is "REJECTED" and reject? then "[#{@deviceManager.getDeviceById(reject).name}]"
        else if _.state is "ERROR" and error? then "[#{error}]"
        else if _.state is "ENABLED" then "[on]"
        else if _.state is "DISABLED" then "[off]"
        else ""

      for k, v of _
        @variableManager.setVariableToValue(@id + '-' + k, if v? then v else "")


  return plugin
