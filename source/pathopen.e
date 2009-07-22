-- (c) Copyright - See License.txt
--

include std/machine.e
include std/os.e
include std/filesys.e
include std/text.e

ifdef DOS32 then
	public include std\dos\memory.e
	include std\dos\interrup.e
end ifdef

include global.e
include common.e
include platform.e

atom oem2char, convert_buffer
integer convert_length
export atom u32,fc_table,char_upper
constant C_POINTER = #02000004

ifdef WIN32 then
	u32=machine_func(50,"user32.dll")
	oem2char=machine_func(51,{u32,"OemToCharA",{C_POINTER,C_POINTER},C_POINTER})
	char_upper=machine_func(51,{u32,"CharUpperA",{C_POINTER},C_POINTER})
	convert_length=64
	convert_buffer=allocate(convert_length)

elsifdef DOS32 then
	sequence regs
	regs=repeat(0,10)
	fc_table=allocate_low(5)
	-- query filename country dependent capitalisation table pointer
	regs[REG_DX]=and_bits(fc_table,15)
	regs[REG_DS]=floor(fc_table/16)
	regs[REG_AX]=#6504
	regs=dos_interrupt(#21,regs)
	if and_bits(regs[REG_FLAGS],1) then -- DOS earlier than 4.0, or something very wrong
		free_low(fc_table)
		fc_table=0
	else -- turn received dword into a 32 bit address, altered so as to access it faster
		regs=peek({fc_table+1,4})
		free_low(fc_table)
		fc_table=regs[1]+256*regs[2]+16*regs[3]+4096*regs[4]-126
	end if
end ifdef

function convert_from_OEM(sequence s)
	integer ls,rc
	
	ls=length(s)
	if ls>convert_length then
		free(convert_buffer)
		convert_length=and_bits(ls+15,-16)+1
		convert_buffer=allocate(convert_length)
	end if
	poke(convert_buffer,s)
	poke(convert_buffer+ls,0)
	rc=c_func(oem2char,{convert_buffer,convert_buffer}) -- always nonzero
	return peek({convert_buffer,ls}) 
end function

constant include_subfolder = SLASH & "include"

integer num_var
sequence 
	cache_vars = {},
	cache_strings = {},
	cache_substrings = {},
	cache_starts = {},
	cache_ends = {},
	cache_converted = {},
	cache_complete = {},
	cache_delims = {}

sequence config_inc_paths = {}
integer loaded_config_inc_paths = 0

object exe_path_cache = 0

sequence pwd = current_dir()

export function exe_path()
	if sequence(exe_path_cache) then
		return exe_path_cache
	end if

	exe_path_cache = command_line()
	exe_path_cache = exe_path_cache[1]
	
	return exe_path_cache
end function

function check_cache(sequence env,sequence inc_path)
	integer delim,pos

	if not num_var then -- first time the var is accessed, add cache entry
		cache_vars = append(cache_vars,env)
		cache_strings = append(cache_strings,inc_path)
		cache_substrings = append(cache_substrings,{})
		cache_starts = append(cache_starts,{})
		cache_ends = append(cache_ends,{})
		ifdef WIN32 then
			cache_converted = append(cache_converted,{})
		end ifdef
		num_var = length(cache_vars)
		cache_complete &= 0
		cache_delims &= 0
		return 0
	else
		if compare(inc_path,cache_strings[num_var]) then
			cache_strings[num_var] = inc_path
			cache_complete[num_var] = 0
			if match(cache_strings[num_var],inc_path)!=1 then -- try to salvage what we can
				pos = -1
				for i=1 to length(cache_strings[num_var]) do
					if cache_ends[num_var][i] > length(inc_path) or 
					  compare(cache_substrings[num_var][i],
					  	inc_path[cache_starts[num_var][i]..cache_ends[num_var][i]]) 
					then
						pos = i-1
						exit
					end if
					if pos = 0 then
						return 0
					elsif pos >0 then -- crop cache data
						cache_substrings[num_var] = cache_substrings[num_var][1..pos]
						cache_starts[num_var] = cache_starts[num_var][1..pos]
						cache_ends[num_var] = cache_ends[num_var][1..pos]
						ifdef WIN32 then
							cache_converted[num_var] = cache_converted[num_var][1..pos]
						end ifdef
						delim = cache_ends[num_var][$]+1
						while delim <= length(inc_path) and delim != PATH_SEPARATOR do
							delim+=1
						end while
						cache_delims[num_var] = delim
					end if
				end for
			end if
		end if
	end if
	return 1
end function


export function get_conf_dirs()
	integer delimiter
	sequence dirs
	
	ifdef UNIX then
		delimiter = ':'
	elsedef
		delimiter = ';'
	end ifdef
	
	dirs = ""
	for i = 1 to length(config_inc_paths) do
		dirs &= config_inc_paths[i]
		if i != length(config_inc_paths) then
			dirs &= delimiter
		end if
	end for
	
	return dirs
end function

function strip_file_from_path( sequence full_path )
	for i = length(full_path) to 1 by -1 do
		if full_path[i] = SLASH then
			return full_path[1..i]
		end if
	end for
	
	return ""
end function

function expand_path( sequence path, sequence prefix )
	integer absolute
	
	if not length(path) then
		return pwd
	end if

	-- TODO: ~ expansion should be modified to work on Windows as well
	ifdef UNIX then
		object home
		if length(path) and path[1] = '~' then
			home = getenv("HOME")
			if sequence(home) and length(home) then
				path = home & path[2..$]
			end if
		end if

		absolute = find(path[1], SLASH_CHARS)
	elsedef
		absolute = find(path[1], SLASH_CHARS) or find(':', path)
	end ifdef
	
	if not absolute then
		path = prefix & SLASH & path
	end if
	
	if length(path) and not find(path[$], SLASH_CHARS) then
		path &= SLASH
	end if
	
	return path
end function

export procedure add_include_directory( sequence path )

	path = expand_path( path, pwd )
   
	if not find( path, config_inc_paths ) then
		config_inc_paths = append( config_inc_paths, path )
	end if
end procedure

sequence seen_conf = {}
export function load_euinc_conf( sequence file )
	integer fn
	object in
	integer spos, epos
	sequence conf_path
	sequence new_args = {}
	sequence arg
	sequence parm
	sequence section

	-- If supplied 'file' is actually a directory name, look for 'euinc.conf' in that directory
	if file_type(file) = FILETYPE_DIRECTORY then
		if file[$] != SLASH then
			file &= SLASH
		end if
		file &= "euinc.conf"
	end if
	
	conf_path = canonical_path( file )
	-- Prevent recursive configuration loads.
	ifdef not UNIX then
		conf_path = lower(conf_path)
	end ifdef
	if find(conf_path, seen_conf) != 0 then
		return {}
	end if
	seen_conf = append(seen_conf, conf_path)
		
	section = "all"
	fn = open( conf_path, "r" )
	if fn = -1 then return {} end if
	
	in = gets( fn )
	while sequence( in ) do
		-- Trim
		spos = 1
		while spos <= length(in) do
			if find( in[spos], "\n\r \t" ) = 0 then
				exit
			end if
			spos += 1
		end while
		
		epos = length(in)
		while epos >= spos do
			if find( in[epos], "\n\r \t" ) = 0 then
				exit
			end if
			epos -= 1
		end while
		
		in = in[spos .. epos]		
		
		
		arg = ""
		parm = ""
    	-- Lines starting with a double dash are comments.
    	-- Blank lines are ignored
    	-- Lines starting with '[' are change of section headers.
    	-- Lines starting with a single dash are option switches
    	-- All other lines are assumed to be '-I' (include path) switch parameters
    	-- Lines of the format '[name]' begin a new section called 'name'. If 'name'
    	--     is omitted, then 'all' is assumed.
		if length(in) > 0 then
			if in[1] = '[' then
				-- Start of a new section
				section = in[2..$]
				if length(section) > 0 and section[$] = ']' then
					section = section[1..$-1]
				end if
				section = lower(trim(section))
				if length(section) = 0 then
					section = "all"
				end if
				
			elsif length(in) > 2 then
				if in[1] = '-' then
					if in[2] != '-' then
						spos = find(' ', in)
						if spos = 0 then
							arg = in
							parm = ""
						else
							arg = in[1..spos - 1]
							parm = in[spos + 1 .. $]
						end if
					end if
				else
					arg = "-I"
					parm = in
				end if
			else
				arg = "-I"
				parm = in
			end if
		end if
		
		if length(arg) > 0 then
			integer needed = 0
			switch section do
				case "all" then
					needed = 1
					
				case "win32" then
					needed = TWINDOWS
			
				case "unix" then
					needed = TUNIX
			
				case "dos32" then
					needed = TDOS
			
				case "translate" then
					needed = TRANSLATE
					
				case "translate:win32", "win32:translate" then
					needed = TRANSLATE and TWINDOWS
					
				case "translate:unix", "unix:translate" then
					needed = TRANSLATE and TUNIX
					
				case "translate:dos32", "dos32:translate" then
					needed = TRANSLATE and TDOS
			
				case "interpret" then
					needed = INTERPRET
					
				case "interpret:win32", "win32:interpret" then
					needed = INTERPRET and TWINDOWS
			
				case "interpret:unix", "unix:interpret" then
					needed = INTERPRET and TUNIX
					
				case "interpret:dos32", "dos32:interpret" then
					needed = INTERPRET and TDOS
			
				case "bind" then
					needed = BIND
					
				case "bind:win32", "win32:bind" then
					needed = BIND and TWINDOWS
			
				case "bind:unix", "unix:bind" then
					needed = BIND and TUNIX
			
				case "bind:dos32", "dos32:bind" then
					needed = BIND and TDOS
		
					
			end switch
			
			if needed then
				arg = upper(arg)
				if equal(arg, "-C") then
					if length(parm) > 0 then
						new_args &= load_euinc_conf(parm)
					end if
				else
					new_args = append(new_args, arg)
					if length(parm > 0) then
						new_args = append(new_args, parm)
					end if
				end if
			end if
		end if
		
		in = gets( fn )
	end while
	close(fn)
	
	return new_args
end function

export function GetDefaultArgs()
	object env
	sequence default_args = {}
	sequence conf_file = "euinc.conf"

	if loaded_config_inc_paths then return "" end if
	loaded_config_inc_paths = 1

	-- If a unix variant, this loads the config file from the current working directory
	-- If Windows, this loads the config file from the same path as the binary. This
	-- can be different, for instance the binary may be C:\euphoria\bin\eui.exe but
	-- you are loading it such as: C:\euphoria\demo> eui demo.ex ... In this case
	-- this command loads C:\euphoria\bin\euinc.conf not C:\euphoria\demo\euinc.conf
	-- as it would under unix variants.
	
	-- platform specific
	ifdef UNIX then
		default_args &= load_euinc_conf( "/etc/euphoria/" & conf_file )
		
		env = getenv( "HOME" )
		if sequence(env) then
			default_args &= load_euinc_conf( env & "/." & conf_file )
		end if
		
	elsifdef WIN32 then
		env = getenv( "ALLUSERSPROFILE" )
		if sequence(env) then
			default_args &= load_euinc_conf( expand_path( "euphoria", env ) & conf_file )
		end if
		
		env = getenv( "APPDATA" )
		if sequence(env) then
			default_args &= load_euinc_conf( expand_path( "euphoria", env ) & conf_file )
		end if

		env = getenv( "HOMEPATH" )
		if sequence(env) then
			default_args &= load_euinc_conf( getenv( "HOMEDRIVE" ) & env & "\\" & conf_file )
		end if
		
	elsedef
		-- none for DOS
	end ifdef
	
	-- From current working directory
	default_args &= load_euinc_conf("./" & conf_file)
	
	-- From where ever the executable is
	env = strip_file_from_path( exe_path() )
	default_args &= load_euinc_conf( env & conf_file )

	return default_args
end function

export function ConfPath(sequence file_name)
-- Search directories listed on command line and in conf files
	sequence file_path
	integer try
	
	for i = 1 to length(config_inc_paths) do
		file_path = config_inc_paths[i] & file_name
		try = open( file_path, "r" )
		if try != -1 then
			return {file_path, try}
		end if
	end for
	return -1
end function

export function ScanPath(sequence file_name,sequence env,integer flag)
-- returns -1 if no path in geenv(env) leads to file_name, else {full_path,handle}
-- if flag is 1, the include_subfolder constant is prepended to filename
	object inc_path
	sequence full_path, file_path, strings
	integer end_path,start_path,try,use_cache, pos

-- 
-- Search directories listed on EUINC environment var
	inc_path = getenv(env)
	if compare(inc_path,{})!=1 then -- nothing to do, just fail
		return -1
	end if

	num_var = find(env,cache_vars)
	use_cache = check_cache(env,inc_path)
	inc_path = append(inc_path, PATH_SEPARATOR)

	file_name = SLASH & file_name
	if flag then
		file_name = include_subfolder & file_name
	end if
	strings = cache_substrings[num_var]

	if use_cache then
		for i=1 to length(strings) do
			full_path = strings[i]
			file_path = full_path & file_name
			try = open(file_path, "r")    
			if try != -1 then
				return {file_path,try}
			end if
			ifdef WIN32 then 
				if sequence(cache_converted[num_var][i]) then
					-- perhaps this path entry, which had never been checked valid, is so 
					-- after conversion
					full_path = cache_converted[num_var][i]
					file_path = full_path & file_name
					try = open(file_path, "r")
					if try != -1 then
						cache_converted[num_var][i] = 0
						cache_substrings[num_var][i] = full_path
						return {file_path,try}
					end if
				end if
			end ifdef
		end for
		if cache_complete[num_var] then -- nothing to scan
			return -1
		else
			pos = cache_delims[num_var]+1 -- scan remainder, starting from as far sa possible
		end if
	else -- scan from scratch
		pos = 1
	end if

	start_path = 0
	for p = pos to length(inc_path) do
		if inc_path[p] = PATH_SEPARATOR then
					-- end of a directory.
			cache_delims[num_var] = p
					-- remove any trailing blanks and SLASH in directory
			end_path = p-1
			while end_path >= start_path and find(inc_path[end_path], " \t" & SLASH_CHARS) do
				end_path-=1
			end while

			if start_path and end_path then
				full_path = inc_path[start_path..end_path]
				cache_substrings[num_var] = append(cache_substrings[num_var],full_path)
				cache_starts[num_var] &= start_path
				cache_ends[num_var] &= end_path
				file_path = full_path & file_name  
				try = open(file_path, "r")
				if try != -1 then -- valid path, no point trying to convert
					ifdef WIN32 then
						cache_converted[num_var] &= 0
					end ifdef
					return {file_path,try}
				end if
				ifdef WIN32 then
					if find(1, full_path>=128) then
						-- accented characters, try converting them
						full_path = convert_from_OEM(full_path)
						file_path = full_path & file_name
						try = open(file_path, "r")
						if try != -1 then -- that was it; record translation as the valid path
							cache_converted[num_var] &= 0
							cache_substrings[num_var] = append(cache_substrings[num_var],full_path)
							return {file_path,try}
						else -- we know we know nothing so far about this path entry
							cache_converted[num_var] = append(cache_converted[num_var],full_path)
						end if
					else -- nothing to convert anyway
						cache_converted[num_var] &= 0
					end if
				end ifdef
				start_path = 0
			end if
		elsif not start_path and (inc_path[p] != ' ' and inc_path[p] != '\t') then
			start_path = p
		end if
	end for
	-- everything failed: mark variable as completely read, so as not to scan again if unmodified
	cache_complete[num_var] = 1
	return -1
end function

sequence include_Paths = {}

export function Include_paths(integer add_converted)
	integer status,pos
	object inc_path
	sequence full_path
	integer start_path,end_path

	if length(include_Paths) then
		return include_Paths
	end if


	include_Paths = append(config_inc_paths, current_dir())
	num_var = find("EUINC", cache_vars)
	inc_path = getenv("EUINC")
	if atom(inc_path) then
		inc_path = ""
	end if
	status = check_cache("EUINC", inc_path)
	if length(inc_path) then
		inc_path = append(inc_path, PATH_SEPARATOR)
	end if

	if status then
		-- some paths are not converted, how to check them?
		if cache_complete[num_var] then
			goto "cache done"
		end if
		pos = cache_delims[num_var]+1
	else
        pos = 1
	end if
	start_path = 0
	for p = pos to length(inc_path) do
		if inc_path[p] = PATH_SEPARATOR then
					-- end of a directory.
			cache_delims[num_var] = p
					-- remove any trailing blanks and SLASH in directory
			end_path = p-1
			while end_path >= start_path and find(inc_path[end_path]," \t" & SLASH_CHARS) do
				end_path -= 1
			end while

			if start_path and end_path then
				full_path = inc_path[start_path..end_path]
				cache_substrings[num_var] = append(cache_substrings[num_var],full_path)
				cache_starts[num_var] &= start_path
				cache_ends[num_var] &= end_path
				ifdef WIN32 then
					if find(1, full_path>=128) then
						-- accented characters, try converting them. There is no guarantee that
						-- the conversion is valid
						cache_converted[num_var] = append(cache_converted[num_var], 
														convert_from_OEM(full_path))
					else -- nothing to convert anyway
						cache_converted[num_var] &= 0
					end if
				end ifdef
				start_path = 0
			end if
		elsif not start_path and (inc_path[p] != ' ' and inc_path[p] != '\t') then
			start_path = p
		end if
	end for

label "cache done"
	include_Paths &= cache_substrings[num_var]
	cache_complete[num_var] = 1

	ifdef WIN32 then
		if add_converted then
	    	for i=1 to length(cache_converted[num_var]) do
	        	if sequence(cache_converted[num_var][i]) then
		        	include_Paths = append(include_Paths, cache_converted[num_var][i])
		        end if
			end for
		end if
	end ifdef
	return include_Paths
end function

-- open a file by searching the user's PATH

export function e_path_open(sequence name, sequence mode)
-- follow the search path, if necessary to open the main file
	integer src_file
	object scan_result

	-- try opening directly
	src_file = open(name, mode)
	if src_file != -1 then
		return src_file        
	end if
	
	-- make sure that name is a simple name without '\' in it
	for i = 1 to length(SLASH_CHARS) do
		if find(SLASH_CHARS[i], name) then
			return -1
		end if
	end for
	
	scan_result = ScanPath(name,"PATH",0)
	if atom(scan_result) then
		return -1
	else
		file_name[1] = scan_result[1]
		return scan_result[2]
	end if
	
end function

