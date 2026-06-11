# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "BRAM_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FORWARD_TLAST" -parent ${Page_0}
  ipgui::add_param $IPINST -name "INCLUDE_CDC" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TDATA_WIDTH" -parent ${Page_0}


}

proc update_PARAM_VALUE.BRAM_ADDR_WIDTH { PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to update BRAM_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BRAM_ADDR_WIDTH { PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to validate BRAM_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.FORWARD_TLAST { PARAM_VALUE.FORWARD_TLAST } {
	# Procedure called to update FORWARD_TLAST when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FORWARD_TLAST { PARAM_VALUE.FORWARD_TLAST } {
	# Procedure called to validate FORWARD_TLAST
	return true
}

proc update_PARAM_VALUE.INCLUDE_CDC { PARAM_VALUE.INCLUDE_CDC } {
	# Procedure called to update INCLUDE_CDC when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.INCLUDE_CDC { PARAM_VALUE.INCLUDE_CDC } {
	# Procedure called to validate INCLUDE_CDC
	return true
}

proc update_PARAM_VALUE.TDATA_WIDTH { PARAM_VALUE.TDATA_WIDTH } {
	# Procedure called to update TDATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TDATA_WIDTH { PARAM_VALUE.TDATA_WIDTH } {
	# Procedure called to validate TDATA_WIDTH
	return true
}


proc update_MODELPARAM_VALUE.TDATA_WIDTH { MODELPARAM_VALUE.TDATA_WIDTH PARAM_VALUE.TDATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TDATA_WIDTH}] ${MODELPARAM_VALUE.TDATA_WIDTH}
}

proc update_MODELPARAM_VALUE.BRAM_ADDR_WIDTH { MODELPARAM_VALUE.BRAM_ADDR_WIDTH PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BRAM_ADDR_WIDTH}] ${MODELPARAM_VALUE.BRAM_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.INCLUDE_CDC { MODELPARAM_VALUE.INCLUDE_CDC PARAM_VALUE.INCLUDE_CDC } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.INCLUDE_CDC}] ${MODELPARAM_VALUE.INCLUDE_CDC}
}

proc update_MODELPARAM_VALUE.FORWARD_TLAST { MODELPARAM_VALUE.FORWARD_TLAST PARAM_VALUE.FORWARD_TLAST } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FORWARD_TLAST}] ${MODELPARAM_VALUE.FORWARD_TLAST}
}

