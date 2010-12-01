# voodoo lagfix functions

get_partition_for()
{
	# resource partition getter which set a global variable named partition
	case $1 in
		cache)	partition=$cache_partition ;;
		dbdata)	partition=$dbdata_partition ;;
		data)	partition=$data_partition ;;
		system)	partition=$system_partition ;;
	esac
}


get_fs_for()
{
	# resource filesystem getter which set a global variable named fs
	case $1 in
		cache)	fs=$cache_fs ;;
		dbdata)	fs=$dbdata_fs ;;
		data)	fs=$data_fs ;;
		system)	fs=$system_fs ;;
	esac
}


set_fs_for()
{
	# resource filesystem getter which set a global variable named fs
	case $1 in
		cache)	cache_fs=$2 ;;
		dbdata)	dbdata_fs=$2 ;;
		data)	data_fs=$2 ;;
		system)	system_fs=$2 ;;
	esac
}


mount_()
{
	get_partition_for $1
	get_fs_for $1

	if test "$fs" = "ext4"; then
		e2fsck -p $partition
		if test $1 = cache; then
			ext4_data_options=',data=writeback'
		else
			ext4_data_options=''
		fi
		# mount as Ext4
		mount -t ext4 -o noatime,barrier=0$ext4_data_options$ext4_options $partition /$1
	else
		# mount as RFS with standard options
		mount -t rfs -o nosuid,nodev,check=no $partition /$1
	fi
}


mount_tmp()
{
	# used during conversions and detection
	mount -t ext4 $1 -o barrier=0,noatime /voodoo/tmp/mnt/ || mount -t rfs -o check=no $1 /voodoo/tmp/mnt/
}


umount_tmp()
{
	umount /voodoo/tmp/mnt
}


log_time()
{
	case $1 in
		start)
			start=`date '+%s'` ;;
		end)
			end=`date '+%s'`
			log 'time spent: '$(( $end - $start ))' s' 1 ;;
	esac
}


ensure_reboot()
{
	# send a message to the watchdog to be sure we reboot even if #
	# reboot command fails
	# loosely using the watchdog device which is supposed
	# to be managed by a watchdog daemonq
	echo 0 > /dev/watchdog
	# trigger reboot with the standard method
	/bin/reboot -f
}


load_stage()
{
	# don't reload a stage already in memory
	if ! test -f /voodoo/run/stage$1_loaded; then
		case $1 in
			2)
				stagefile="/voodoo/stage2.tar.lzma"
				if test -f $stagefile; then
					# this stage is in ramdisk. no security check
					log "load stage2"
					lzcat $stagefile | tar xv
				else
					log "no stage2 to load"
				fi
				;;
			*)
				# give the option to load without signature
				# from the ramdisk itself
				# useful for testing and when size don't matter
				if test -f /voodoo/stage$1.tar.lzma; then
					log "load stage $1 from ramdisk"
					lzcat /voodoo/stage$1.tar.lzma | tar xv
				else

					stagefile="/sdcard/Voodoo/resources/stage$1.tar.lzma"

					# load the designated stage after verifying it's
					# signature to prevent security exploit from sdcard
					if test -f $stagefile; then
						retcode=1
						signature=`sha1sum $stagefile | cut -d' ' -f 1`
						for x in `cat /voodoo/signatures/stage$1`; do
							if test "$x" = "$signature"  ; then
								retcode=0
								log "load stage $1 from SD"
								lzcat $stagefile | tar xv
								break
							fi
						done
					fi
					test retcode = 1 && log "stage $1 not loaded, stage file don't exist"
				fi
				;;
		esac
		> /voodoo/run/stage$1_loaded
	fi
	return $retcode
}


detect_supported_model_and_setup_partitions()
{
	 # read the actual MBR
	dd if=/dev/block/mmcblk0 of=/voodoo/tmp/original.mbr bs=512 count=1

	for x in /voodoo/mbrs/* ; do
		if cmp $x /voodoo/tmp/original.mbr; then
			model=`echo $x | /bin/cut -d \/ -f4`
			break
		fi
	done

	if test $model != ""; then 
		log "model detected: $model"
		
		# fascinate is different here
		if test "$model" = 'fascinate'; then
			data_partition='/dev/block/mmcblk0p1'
			sdcard_device='/dev/block/mmcblk1p1'
		else
		# for every other model
			data_partition='/dev/block/mmcblk0p2'
			sdcard_device='/dev/block/mmcblk0p1'
		fi
		echo "data_partition='$data_partition'" >> /voodoo/configs/partitions

	else
		return 1
	fi
}


detect_fs_on()
{
	resource=$1
	get_partition_for $resource
	log "filesystem detection on $resource:"
	if tune2fs -l $partition 1>&2; then
		# we found an ext2/3/4 partition. but is it real ?
		# if the data partition mounts as rfs, it means
		# that this Ext4 partition is just lost bits still here
		if mount -t rfs -o ro,check=no $partition /voodoo/tmp/mnt data; then
			log "RFS on $partition: Ext4 bits found but from an invalid and corrupted filesystem" 1
			umount_tmp
			echo rfs
			return
		fi
		log "Ext4 on $partition" 1
		echo ext4
		return
	fi
	log "RFS on $partition" 1
	echo rfs
}


detect_all_filesystems()
{
	system_fs=`detect_fs_on system`
	dbdata_fs=`detect_fs_on dbdata`
	cache_fs=`detect_fs_on cache`
	data_fs=`detect_fs_on data`
}


configure_from_kernel_version()
{
	if test "`cat /proc/version | cut -d'.' -f 3`" = 32; then
		kversion="2.6.32"
		ext4_options=",noauto_da_alloc"
	fi
}


log()
{
	indent=""
	test "$2" = 1 && indent="    "
	test "$2" = 2 && indent="        "
	echo "`date '+%Y-%m-%d %H:%M:%S'` $indent $1" >> /voodoo/logs/voodoo_log.txt
}


say()
{
	test "$silent" = 1 && return
	# sound system lazy loader
	if load_soundsystem; then 
		# play !
		madplay -A -4 -o wave:- "/voodoo/voices/$1.mp3" 2> /dev/null | \
			 aplay -Dpcm.AndroidPlayback_Speaker --buffer-size=4096
	fi
}


load_soundsystem()
{
	# load alsa libs & players
	load_stage 3-sound

	# cache the voices from the SD to the ram
	# with a size limit to prevent filling memory security expoit
	if ! test -d /voodoo/voices; then
		if test -d /sdcard/Voodoo/resources/voices/; then
			if test "`du -s /sdcard/Voodoo/resources/voices/ | cut -d \/ -f1`" -le 1024; then
				# copy the voices (no cp command, use cat)
				cp -r /sdcard/Voodoo/resources/voices /voodoo/
				log "voices loaded"
			else
				log "ERROR: voice diretory strangely big"
				retcode=1
			fi
		else
			log "no voice directory, silent mode"
			retcode=1
		fi
	fi
	return $retcode
}


verify_voodoo_install()
{
	for x in /sbin/fat.format /system/bin/fat.format; do
		# manage Froyo & Eclair
		test "$x" = "/sbin/fat.format" && prefix="/sbin" || prefix="/system/bin"
		test -x "$prefix/fat.format" && log "manage fat.format in $prefix" || continue

		# if the wrapper is not the same as the one in this ramdisk, we install it
		if ! cmp /voodoo/system_scripts/fat.format_wrapper.sh "$prefix/fat.format_wrapper.sh"; then
			cp /voodoo/system_scripts/fat.format_wrapper.sh "$prefix/fat.format_wrapper.sh"
			log "fat.format wrapper installed in $prefix"
		else
			log "fat.format wrapper already installed in $prefix"
		fi

		# now, check the validity of the symlink
		if ! test -L "$prefix/fat.format" && test -x "$prefix/fat.format_wrapper.sh" ; then

			# if fat.format is not a symlink, it means that it's
			# Samsung's binary. Let's rename it
			mv "$prefix/fat.format" "$prefix/fat.format.real"
			ln -s fat.format_wrapper.sh "$prefix/fat.format"
			log "fat.format renamed to fat.format.real & symlink created to fat.format_wrapper.sh"
		fi
	done
}


in_recovery()
{
	if test "`cut -d' ' -f 1 /proc/cmdline`" = "bootmode=2"; then
		log_suffix='-recovery'
		return 0
	else
		return 1
	fi
}


detect_cwm_recovery()
{
	if  test -f /cache/update.zip && test "$recovery_command" = "--update_package=CACHE:update.zip"; then
			# check if this is a real CWM update.zip

			log "analyze CACHE:update.zip to see if it's CWM recovery"
			testdir="/voodoo/tmp/cwm-detection"
			mkdir $testdir
			unzip /cache/update.zip sbin/recovery sbin/adbd -d /voodoo/tmp/cwm-detection

			if test -f $testdir/sbin/recovery && test -f $testdir/sbin/adbd; then
				rm -rf $testdir
				log "CWM recovery found"
				return 0
			fi
	else
		if test -d /cwm && test -f /cwm/sbin/recovery && test -f /cwm/sbin/adbd; then
			# CWM is already present in this ramdisk
			# run it only if we are not supposed to run other commands
			# like CSC updates or OTAs
			log "CWM recovery present in /cwm"
			if test "$recovery_command" = ''; then
				log "no recovery command specified, Ok for CWM"
				return 0
			else
				log "recovery command specified, aborting CWM launch"
				return 1
			fi
		fi
	fi
	# no CWM detected
	return 1
}


check_available_space()
{
	log "check space availability for $resource:" 1
	
	# mount resource to check for space, except if it's system (already mounted)
	test $resource != system && mount_ $resource

	# read free space on internal SD
	sdcard_available=$((`df /sdcard | cut -d' ' -f 6 | cut -d K -f 1` / 1024 ))

	# read space used by data we need to backup
	resource_used=$((`df /$resource | cut -d' ' -f 4 | cut -d K -f 1` / 1024 ))

	# read space free on the partition we need to backup
	resource_available=$((`df /$resource | cut -d' ' -f 6 | cut -d K -f 1` / 1024 ))

	log "available:        $resource_available MB" 2
	log "used:             $resource_used MB" 2
	log "sdcard available: $sdcard_available MB" 2

	# check if the Ext4 overhead let us enough space
	if test $dest_fs = ext4; then
		log "check Ext4 additionnal disk usage for $resource" 1
		case $resource in
			system)	overhead=7 ;;
			data)	overhead=20 ;;
			dbdata)	overhead=14 ;;
			dbdata)	overhead=0 ;; # cache? don't care
		esac

		if test $resource_available -lt $overhead; then
			log "$resource partition space usage too high to convert to Ext4" 2
			log "missing: "$(( $overhead - $resource_available )) 2

			if test $resource = system; then
				log "disabling /system conversion by configuration"
				disallow_system_conversion
			fi
			available_space_error='partition'
			return 2
		else
			log "enough free space on /$resource to convert to Ext4" 2
		fi
	fi

	# umount the resource if it's not /system
	test "$resource" != "system" && umount /$resource

	# ask for 1% more free space for security reasons
	if ! test $sdcard_available -ge $(( $resource_used + $resource_used / 100)); then
		available_space_error='sdcard'
		return 1
	fi
	return 0
}


rfs_format()
{
	log "format $1 as RFS using Android init + a fake init.rc to run fat.format" 1
	# communicate with the formatter script
	echo "$1" > /voodoo/run/rfs_format_what

	# save real init .rc files
	mv *.rc /voodoo/tmp/

	# create rc for every condition
	cp /voodoo/scripts/rfs_formatter.rc init.rc
	ln -s init.rc recovery.rc
	ln -s init.rc fota.rc
	ln -s init.rc lpm.rc

	# run init that will run the actual format script
	/init_samsung
	umount /dev/pts
	umount /dev
	echo >> $log_dir/rfs_formatter_log.txt

	# let's restore the original .rc files
	rm *.rc
	mv /voodoo/tmp/*.rc ./
}


ext4_format()
{
	if test $resource = "data"; then
		journal_size=12
		features='sparse_super,'
	else
		journal_size=4
		features=''
	fi
	mkfs.ext4 -F -O "$features"^resize_inode -J size=$journal_size -T default $partition
	# force check the filesystem after 100 mounts or 100 days
	tune2fs -c 100 -i 100d -m 0 $partition
}


copy_system_in_ram()
{
	if ! test -d /system_in_ram; then
		# save /system stuff
		log "make a limited copy of /system in ram" 1
		mkdir -p /system_in_ram/bin
		cp	/system/bin/toolbox \
			/system/bin/sh \
			/system/bin/log \
			/system/bin/linker \
			/system/bin/fat.format*  /system_in_ram/bin/

		mkdir -p /system_in_ram/lib/
		cp 	/system/lib/liblog.so \
			/system/lib/libc.so \
			/system/lib/libstdc++.so \
			/system/lib/libm.so \
			/system/lib/libcutils.so /system_in_ram/lib/
		umount /system
		ln -s /system_in_ram/* /system
	fi
}



build_archive()
{
	rm -rf /voodoo/tmp/mnt/lost+found
	time tar cv /voodoo/tmp/mnt/ 2> $log_dir/"$1"_list.txt \
		| lzop | dd bs=$(( 4096 * 512 )) of=$archive
}


extract_archive()
{
	time dd if=$archive bs=$(( 4096 * 512 )) | lzopcat | tar xv > $log_dir/"$1"_list.txt 2>&1
}


convert()
{
	resource="$1"
	dest_fs="$2"
	test conversion_happened = '' && conversion_happened=0
	
	# use global getters
	get_partition_for $resource
	get_fs_for $resource

	source_fs=$fs

	if test $source_fs = $dest_fs; then
		log "no need to convert $resource"
		return
	fi

	if test -f /voodoo/run/no_sdcard; then
		# this can happens on Fascinate only
		log "no SD Card is available, cannot proceed to conversion"
		return 1
	fi

	log "convert $resource ($partition) from $source_fs to $dest_fs"

	archive=/sdcard/voodoo_"$resource"_conversion.tar.lzo
	archive_saved=/sdcard/voodoo_"$resource"_conversion_saved.tar.lzo
	rm -f $archive $archive_saved

	# tag the log for easier analysis
	if test $resource = cache || test $resource = dbdata; then
		silent=1
	else
		log_suffix='-conversion'
		silent=0
		say "convert-$resource"
	fi

	# be sure fat.format is in PATH
	if test "$dest_fs" = "rfs"; then
		fat.format > /dev/null 2>&1
		if test "$?" = 127; then
			log "ERROR: unable to call fat.format: cancel conversion" 1
			return 1
		fi
	fi

	# make sure df is there or cancel conversion
	if ! df > /dev/null 2>&1 ; then
		log "ERROR: unable to call the df command from system, cancel conversion" 1
		say "no-system"
		return 1
	fi

	# check for free space in sd
	if ! check_available_space $resource; then
		case $available_space_error in
			sdcard)
				log "WARNING: not enough space on sdcard to convert $resource" 1
				say "not-enough-space-sdcard"
				;;
			partition)
				say "not-enough-space-partition"
			;;
		esac
		log "$resource conversion cancelled" 1
		return 1
	else
		case $resource in
			system)
				# on small /system ROMS it takes less time, 2 minutes is a pessimistic prediction ;)
				say "time-estimated"
				say "2-minutes" ;;
			data)
				if test $dest_fs = 'rfs'; then
					# Converting to RFS takes a lot of time
					# measured to 60MB converted by minute
					test $resource_used -gt 45 && say "time-estimated"

					( test $resource_used -gt 45 && test $resource_used -le 60 && say "1-minute" ) || \
					( test $resource_used -gt 60 && test $resource_used -le 120 && say "2-minutes"  ) || \
					( test $resource_used -gt 120 && test $resource_used -le 180 && say "3-minutes" ) || \
					( test $resource_used -gt 180 && test $resource_used -le 240 && say "4-minutes" ) || \
					( test $resource_used -gt 240 && test $resource_used -le 300 && say "5-minutes" ) || \
					( test $resource_used -gt 300 && test $resource_used -le 600 && say "10-minutes" ) || \
					( test $resource_used -gt 600 && test $resource_used -le 900 && say "15-minutes" ) || \
					( test $resource_used -gt 900 && say "20-minutes+" )
				else
					# Converting to Ext4 takes less time
					# measured to 104MB converted by minute
					test $resource_used -gt 75 && say "time-estimated"

					( test $resource_used -gt 75 && test $resource_used -le 104 && say "1-minute" ) || \
					( test $resource_used -gt 104 && test $resource_used -le 208 && say "2-minutes"  ) || \
					( test $resource_used -gt 208 && test $resource_used -le 312 && say "3-minutes" ) || \
					( test $resource_used -gt 312 && test $resource_used -le 416 && say "4-minutes" ) || \
					( test $resource_used -gt 416 && test $resource_used -le 520 && say "5-minutes" ) || \
					( test $resource_used -gt 520 && test $resource_used -le 1040 && say "10-minutes" ) || \
					( test $resource_used -gt 1040 && test $resource_used -le 1560 && say "15-minutes" ) || \
					( test $resource_used -gt 1560 && say "20-minutes+" )
				fi ;;
		esac
	fi

	# in case we convert /system to RFS, we need to keep a copy of
	# some tools from here
	if test "$dest_fs" = "rfs" && test "$resource" = "system"; then
		copy_system_in_ram
		# /system has been unmounted
		remount_system=1
	fi

	log "backup $resource" 1
	say "backup"

	if ! mount_tmp $partition; then
		log "ERROR: unable to mount $partition" 1
		return 1
	fi

	log_time start
	# archive management
	if ! build_archive "$resource"_to_"$dest_fs"_backup; then
		log "ERROR: problem during $resource backup, the filesystem must be corrupt" 1
		log "This error comes after an RFS filesystem has been mounted without the standard -o check=no" 1
		if test $source_fs = rfs; then
			log "Attempting a mount with broken RFS options" 1
			# archive management
			mount -t rfs -o ro $partition /voodoo/tmp/mnt/
			if ! build_archive "$resource"_to_"$dest_fs"_backup_nocheckno; then
				log "Unable to save a correct backup: cancel conversion" 2
				umount_tmp
				return 1
			else
				log "second attempt successful"
			fi
		fi
	fi
	umount_tmp
	log_time end

	log "format $partition" 1
	if test "$dest_fs" = "rfs"; then
		rfs_format $resource
		set_fs_for $resource rfs
	else
		test $resource = system && umount /system && remount_system=1
		ext4_format
		set_fs_for $resource ext4
	fi

	log "restore $resource" 1
	say 'restore'

	if ! mount_tmp $partition; then
		log "ERROR: unable to mount $partition to restore the backup" 1
		log "this error is known to happens because of the RFS driver mount bug"
		log "reboot and catch the error later"
		umount_tmp
		log_suffix='-RFS-bug-hit'
		manage_logs
		ensure_reboot
		# past here this code is supposed to be never excecuted
		return 1
	fi

	log_time start
	# archive management
	if ! extract_archive "$resource"_to_"$dest_fs"_restore; then
		log "ERROR: problem during $resource restore" 1
		umount_tmp
		return 1
	fi
	log_time end

	# deal with archive file
	if test "$debug_mode" = 1; then
		mv $archive $archive_saved
	else
		rm $archive
	fi

	umount_tmp

	# remount /system if needed
	test "$remount_system" = 1 && mount_ system

	conversion_happened=1

	# conversion is successful
	return 0
}



finalize_interrupted_rfs_conversion()
{
	# thanks to Mish for the original reboot idea

	min_size=500
	was_finalized=0

	asoundconf=/sdcard/Voodoo/asound.conf
	test -f $asoundconf && cp $asoundconf /etc/

	for resource in dbdata data system; do
		archive=/sdcard/voodoo_"$resource"_conversion.tar.lzo
		archive_ignored=/sdcard/voodoo_"$resource"_conversion_ignored.tar.lzo

		# check if the /system archive is there and is more than 20MB
		if test -f $archive; then

			# /system is already mounted but not other resources
			test $resource != system && mount_ $resource

			# check if the resource partition is empty (or at contains less than $min_size of data)
			if test `du -s /$resource | cut -d/ -f1` -lt $min_size; then
				# we don't want watchdog rebooting on us here
				echo -n V > /dev/watchdog

				say 'restore'

				log "finalize /$resource conversion to RFS: restore backup"
				rm -rf /$resource/*
				umount /$resource

				log_time start
				mount_tmp $partition
				# archive management
				if extract_archive "$resource"_rfs_conversion_workaround_restore; then
					log_time end
					log "/$resource backup restored, workaround successful" 1
					rm $archive
				else
					mv $archive /sdcard/voodoo_"$archive"_conversion_failed_restore.tar.lzo
					log "/$resource restore error, unrecoverable error" 1
					log "attempt boot to recovery" 1
					/system/bin/reboot recovery
				fi
				umount_tmp

				test $resource = system && mount_ $resource
				was_finalized=1
			else
				log "found a /$resource conversion temporary archive but the partition looks already okay"
				log "/sdcard/voodoo_"$resource'_conversion.tar.lzo ignored'
				if $debug_mode = 1; then
					mv $archive $archive_ignored
				else
					rm $archive
				fi
			fi
		fi
	done


	# if we rebooted here using the watchdog's facility, we are maybe in reality
	# in battery charging mode. As it is difficult to detect, lets just reboot
	if test $was_finalized = 1; then
		log "rebooting to the normal mode"
		log_suffix='-RFS-bug-workaround'
		manage_logs
		ensure_reboot
	fi
}


manage_logs()
{
	# Manage logs
	# clean up old logs on sdcard (more than 7 days)
	find /sdcard/Voodoo/logs/ -mtime +7 -delete

	# manage the voodoo_history log
	tail -n 1000 /sdcard/Voodoo/logs/voodoo_history_log.txt > /voodoo/logs/voodoo_history_log.txt
	echo >> /voodoo/logs/voodoo_history_log.txt
	cat /voodoo/logs/voodoo_history_log.txt /voodoo/logs/voodoo_log.txt > /sdcard/Voodoo/logs/voodoo_history_log.txt
	# save current voodoo_log in the sdcard
	cp /voodoo/logs/voodoo_log.txt $log_dir/

	# manage other logs
	cp $log_dir/* /voodoo/logs

	current_log_directory=`date '+%Y-%m-%d_%H-%M-%S'`$log_suffix
	mv $log_dir /sdcard/Voodoo/logs/$current_log_directory
}


readd_boot_animation()
{
	echo >> init.rc
	if test -f /data/local/bootanimation.zip || test -f /system/media/bootanimation.zip; then
		echo 'service bootanim /system/bin/bootanimation
			user graphics
			group graphics
			disabled
			oneshot' >> init.rc
	else
		echo 'service playlogos1 /system/bin/playlogos1
			user root
			oneshot' >> init.rc
	fi
}


letsgo()
{
	# free ram
	rm -rf /system_in_ram

	# deal with the boot animation
	mount_ data
	readd_boot_animation
	umount /data

	# mount Ext4 partitions
	test $cache_fs = ext4 && mount_ cache && > /voodoo/run/lagfix_enabled
	test $dbdata_fs = ext4 && mount_ dbdata && > /voodoo/run/lagfix_enabled
	test $data_fs = ext4 && mount_ data && > /voodoo/run/lagfix_enabled

	test "$conversion_happened" = 1 && say "lagfix-status-"$lagfix_enabled

	# remove the tarball in maximum compression mode
	rm -f compressed_voodoo_ramdisk.tar.lzma

	verify_voodoo_install

	# if /data is an Ext4 filesystem, it means we need to activate
	# the fat.format wrapper protection
	test "$data_fs" = "ext4" && > /voodoo/run/lagfix_enabled
	
	# run additionnal extensions scripts
	# actually they are sourced so they can use the init functions,
	# resources and variables
	
	if test "`find /voodoo/extensions/ -name '*.sh'`" != "" ; then
		for x in /voodoo/extensions/*.sh; do
			log "running extension: `echo $x | cut -d'/' -f 4`"
			. "$x"
		done
	fi

	log "running init !"

	#readd_boot_animation
	manage_logs

	# remove voices from memory
	rm -r /voodoo/voices

	# boot successful, no need to keep asound.conf on the sdcard
	rm /sdcard/Voodoo/asound.conf

	# remove CWM setup files
	rm -rf /cwm

	# set the etc to Android standards
	rm /etc
	# on Froyo ramdisk, there is no etc to /etc/system symlink anymore

	if test "$system_fs" = "rfs"; then
		umount /system
	fi
	
	# exit this main script (the runner will execute samsung_init )
	exit
}
