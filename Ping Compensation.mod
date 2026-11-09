return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Ping Compensation` mod must be lower than Vermintide Mod Framework in your launcher's load order.")

		new_mod("Ping Compensation", {
			mod_script       = "scripts/mods/Ping Compensation/Ping Compensation",
			mod_data         = "scripts/mods/Ping Compensation/Ping Compensation_data",
			mod_localization = "scripts/mods/Ping Compensation/Ping Compensation_localization",
		})
	end,
	packages = {
		"resource_packages/Ping Compensation/Ping Compensation",
	},
}
