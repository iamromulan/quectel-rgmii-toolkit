#!/bin/bash

# Adapted to work with RJ45 / Quectel Board Dev 
# Quectel AT Parsing Original source ROOter2203 
# https://github.com/ofmodemsandmen/ROOterSource2203/blob/6636758b945ff16b6c5b54494de04b74b011c204/package/rooter/ext-rooter-basic/files/usr/lib/rooter/common/quecteldata.sh
#


rspr2rssi() {
	echo ${RSCP} ${BW_N} | awk '{printf "%.0f\n", (($1+10*log(12*$2)/log(10)))}'
}

lte_bw() {
	BW=$(echo $BW | grep -o "[0-5]\{1\}")
	case $BW in
		"0")
			BW="1.4" ;;
		"1")
			BW="3" ;;
		"2"|"3"|"4"|"5")
			BW=$((($(echo $BW) - 1) * 5)) ;;
	esac
}

nr_bw() {
	BW=$(echo $BW | grep -o "[0-9]\{1,2\}")
	case $BW in
		"0"|"1"|"2"|"3"|"4"|"5")
			BW=$((($(echo $BW) + 1) * 5)) ;;
		"6"|"7"|"8"|"9"|"10"|"11"|"12")
			BW=$((($(echo $BW) - 2) * 10)) ;;
		"13")
			BW="200" ;;
		"14")
			BW="400" ;;
	esac
}

# Function to get the secondary LTE & NR5G bands
get_secondary_bands() {
	# Extract LTE BANDs from SCC lines
	SCC_BANDS=$(echo "$OX" | grep '+QCAINFO: "SCC"' | grep -o '"LTE BAND [0-9]\+"' | tr -d '"' | sed '1d')
	
	# Extract NR5G BANDs from SCC lines
	NR_BAND=$(echo "$OX" | grep '+QCAINFO: "SCC"' | grep -o '"NR5G BAND [0-9]\+"' | tr -d '"' | sed '1d')
	
	# Check if both SCC and NR bands are non-empty
	if [ -n "$SCC_BANDS" ] && [ -n "$NR_BAND" ]; then
		# Concatenate LTE BANDs with NR5G BANDs
		SC_BANDS="$SCC_BANDS<br />$NR_BAND"
	else
		# Set SC_BANDS to the non-empty variable or empty if both are empty
		SC_BANDS="${SCC_BANDS}${NR_BAND}"
	fi
}

# Get the modem model from /tmp/modemmodel.txt and parse it
MODEM_MODEL=$(</tmp/modemmodel.txt)
# Get the model name from the modem model (they either start with RG or RM)
MODEM_MODEL=$(echo "$MODEM_MODEL" | grep -o "RG[^ ]\+\|RM[^ ]\+")

# Get the APN from /tmp/apn.txt and parse it
APN=$(</tmp/apn.txt)
APN=$(echo "$APN" | grep -o '"[^"]*"' | head -n1 | tr -d '"')

# Get the SIM slot from /tmp/simslot.txt and parse it
# simslot.txt looks like this: +QUIMSLOT: 1
SIMSLOT=$(</tmp/simslot.txt)
SIMSLOT=$(echo "$SIMSLOT" | grep -o "[0-9]")
# Append SIM before the SIM slot number
SIMSLOT="SIM "$SIMSLOT

# Read File
OX=$(</tmp/modemstatus.txt)

OX=$(echo $OX | tr 'a-z' 'A-Z')

RSRP=""
RSRQ=""
CHANNEL="-"
ECIO="-"
RSCP="-"
ECIO1=" "
RSCP1=" "
MODE="-"
MODTYPE="-"
NETMODE="-"
LBAND="-"
PCI="-"
CTEMP="-"
SINR="-"
COPS="-"
COPS_MCC="-"
COPS_MNC="-"
CID=""
CID5=""
RAT=""
QSPN=$(echo $OX | grep -o '+QSPN: "[^"]*","[^"]*","[^"]*",[^"]*,"[^"]*"' | cut -c 8-)
#  GET MCCMNC from the last field of QSPN
MCCMNC=$(echo $QSPN | cut -d, -f5 | tr -d '"')
PROVIDER=$(echo $QSPN | cut -d, -f1 | tr -d '"')
PROVIDER_ID=$(echo $QSPN | cut -d, -f5 | tr -d '"')
CSQ=$(echo $OX | grep -o "+CSQ: [0-9]\{1,2\}" | grep -o "[0-9]\{1,2\}")
if [ "$CSQ" = "99" ]; then
	CSQ=""
fi
if [ -n "$CSQ" ]; then
	CSQ_PER=$(($CSQ * 100/31))"%"
	CSQ_RSSI=$((2 * CSQ - 113))" dBm"
else
	CSQ="-"
	CSQ_PER="-"
	CSQ_RSSI="-"
fi
get_secondary_bands
# End of QCAINFO 
NR_NSA=$(echo $OX | grep -o "+QENG:[ ]\?\"NR5G-NSA\",")
NR_SA=$(echo $OX | grep -o "+QENG: \"SERVINGCELL\",[^,]\+,\"NR5G-SA\",\"[DFT]\{3\}\",")
if [ -n "$NR_NSA" ]; then
	QENG=",,"$(echo $OX" " | grep -o "+QENG: \"LTE\".\+\"NR5G-NSA\"," | tr " " ",")
	if [ -z "$QENG5" ]; then
		# Fixed an issue where the last 2 digits were not included in the regex
		QENG5=$(echo $OX | grep -o "+QENG:[ ]\?\"NR5G-NSA\",[0-9]\{3\},[0-9]\{2,3\},[0-9]\{1,5\},-[0-9]\{2,3\},[-0-9]\{1,3\},-[0-9]\{2,3\},[0-9]\{1,6\},[0-9]\{1,3\},[0-9]\{1,3\},[0-9]\{1,3\}")
		if [ -n "$QENG5" ]; then
			QENG5=$QENG5",,"
		fi
	fi
elif [ -n "$NR_SA" ]; then
	QENG=$(echo $NR_SA | tr " " ",")
	QENG5=$(echo $OX | grep -o "+QENG: \"SERVINGCELL\",[^,]\+,\"NR5G-SA\",\"[DFT]\{3\}\",[ 0-9]\{3,4\},[0-9]\{2,3\},[0-9A-F]\{1,10\},[0-9]\{1,5\},[0-9A-F]\{2,6\},[0-9]\{6,7\},[0-9]\{1,3\},[0-9]\{1,2\},-[0-9]\{2,5\},-[0-9]\{2,3\},[-0-9]\{1,3\}")
else
	QENG=$(echo $OX" " | grep -o "+QENG: [^ ]\+ " | tr " " ",")
fi
QCA=$(echo $OX" " | grep -o "+QCAINFO: \"S[CS]\{2\}\".\+NWSCANMODE" | tr " " ",")
QNSM=$(echo $OX | grep -o "+QCFG: \"NWSCANMODE\",[0-9]")
QNWP=$(echo $OX | grep -o "+QNWPREFCFG: \"MODE_PREF\",[A-Z5:]\+" | cut -d, -f2)
QTEMP=$(echo $OX | grep -o "+QTEMP: [0-9]\{1,3\}")
if [ -z "$QTEMP" ]; then
	QTEMP=$(echo $OX | grep -o "+QTEMP:[ ]\?\"XO[_-]THERM[_-][^,]\+,[\"]\?[0-9]\{1,3\}" | grep -o "[0-9]\{1,3\}")
fi
if [ -z "$QTEMP" ]; then
	QTEMP=$(echo $OX | grep -o "+QTEMP:[ ]\?\"MDM-CORE-USR.\+[0-9]\{1,3\}\"" | cut -d\" -f4)
fi
if [ -z "$QTEMP" ]; then
	QTEMP=$(echo $OX | grep -o "+QTEMP:[ ]\?\"MDMSS.\+[0-9]\{1,3\}\"" | cut -d\" -f4)
fi
if [ -n "$QTEMP" ]; then
	CTEMP=$(echo $QTEMP | grep -o "[0-9]\{1,3\}")$(printf "\xc2\xb0")"C"
fi
RAT=$(echo $QENG | cut -d, -f4 | grep -o "[-A-Z5]\{3,7\}")


rm -f /tmp/modnetwork
case $RAT in
	"GSM")
		MODE="GSM"
		;;
	"WCDMA")
		MODE="WCDMA"
		CHANNEL=$(echo $QENG | cut -d, -f9)
		RSCP=$(echo $QENG | cut -d, -f12)
		RSCP="-"$(echo $RSCP | grep -o "[0-9]\{1,3\}")
		ECIO=$(echo $QENG | cut -d, -f13)
		ECIO="-"$(echo $ECIO | grep -o "[0-9]\{1,3\}")
		;;
	"LTE"|"CAT-M"|"CAT-NB")
		MODE=$(echo $QENG | cut -d, -f5 | grep -o "[DFT]\{3\}")
		if [ -n "$MODE" ]; then
			MODE="$RAT $MODE"
		else
			MODE="$RAT"
		fi
		PCI=$(echo $QENG | cut -d, -f9)
		CHANNEL=$(echo $QENG | cut -d, -f10)
		LBAND=$(echo $QENG | cut -d, -f11 | grep -o "[0-9]\{1,3\}")
		BW=$(echo $QENG | cut -d, -f12)
		lte_bw
		BWU=$BW
		BW=$(echo $QENG | cut -d, -f13)
		lte_bw
		BWD=$BW
		if [ -z "$BWD" ]; then
			BWD="unknown"
		fi
		if [ -z "$BWU" ]; then
			BWU="unknown"
		fi
		if [ -n "$LBAND" ]; then
			PC_BAND="LTE BAND "$LBAND
			LBAND="B"$LBAND" (Bandwidth $BWD MHz Down | $BWU MHz Up)"
		fi
		RSRP=$(echo $QENG | cut -d, -f15 | grep -o "[0-9]\{1,3\}")
		if [ -n "$RSRP" ]; then
			RSCP="-"$RSRP
			RSRPLTE=$RSCP
		fi
		RSRQ=$(echo $QENG | cut -d, -f16 | grep -o "[0-9]\{1,3\}")
		if [ -n "$RSRQ" ]; then
			ECIO="-"$RSRQ
		fi
		RSSI=$(echo $QENG | cut -d, -f17 | grep -o "\-[0-9]\{1,3\}")
		if [ -n "$RSSI" ]; then
			CSQ_RSSI=$RSSI" dBm"
		fi
		SINRR=$(echo $QENG | cut -d, -f18 | grep -o "[0-9]\{1,3\}")
		if [ -n "$SINRR" ]; then
			if [ $SINRR -le 25 ]; then
				SINR=$((($(echo $SINRR) * 2) -20))" dB"
			fi
		fi
		if [ -n "$(echo $QENG | cut -d, -f21)" ]; then
			CQI=$(echo $QENG | cut -d, -f19 | grep "^[0-9]\+$")
			if [ -n "$SINR" -a -n "$CQI" -a "$CQI" != "0" ]; then
				SINR=$SINR" (CQI $CQI)"
			fi
		fi
		if [ -n "$NR_NSA" ]; then
			MODE="LTE/NR EN-DC"
			echo "0" > /tmp/modnetwork
			if [ -n "$QENG5" ]; then
				QENG5=$QENG5",,"
				# Append the initial PCI value rather than overwriting it
				PCI="$PCI, "$(echo $QENG5 | cut -d, -f4)
				SCHV=$(echo $QENG5 | cut -d, -f8)
				SLBV=$(echo $QENG5 | cut -d, -f9) # Now correctly captures the NR band
				BW=$(echo $QENG5 | cut -d, -f10) # Now gets the correct BW
				if [ -n "$SLBV" ]; then
					LBAND=$LBAND"<br />n"$SLBV
					if [ -n "$BW" ]; then
						nr_bw
						LBAND=$LBAND" (Bandwidth $BW MHz)"
					fi
					if [ "$SCHV" -ge 123400 ]; then
						CHANNEL=$CHANNEL", "$SCHV
					else
						CHANNEL=$CHANNEL", -"
					fi
				else
					# removed the (unknown NR5G BAND) and replaced with No NR5G Band to avoid confusion
					LBAND=$LBAND"<br />No NR5G Band Detected"
					CHANNEL=$CHANNEL", -"
				fi
				RSCP=$RSCP" dBm<br />"$(echo $QENG5 | cut -d, -f5)
				SINRR=$(echo $QENG5 | cut -d, -f6 | grep -o "[0-9]\{1,3\}")
				if [ -n "$SINRR" ]; then
					if [ $SINRR -le 30 ]; then
						SINR=$SINR"<br />"$((($(echo $SINRR) * 2) -20))" dB"
					fi
				fi
				ECIO=$ECIO" (4G) dB<br />"$(echo $QENG5 | cut -d, -f7)" (5G) "
			fi
		fi
		if [ -z "$LBAND" ]; then
			LBAND="-"
		else
			if [ -n "$QCA" ]; then
				QCA=$(echo $QCA | grep -o "\"S[CS]\{2\}\"[-0-9A-Z,\"]\+")
				for QCAL in $(echo "$QCA"); do
					if [ $(echo "$QCAL" | cut -d, -f7) = "2" ]; then
						SCHV=$(echo $QCAL | cut -d, -f2 | grep -o "[0-9]\+")
						SRATP="B"
						if [ -n "$SCHV" ]; then
							CHANNEL="$CHANNEL, $SCHV"
							if [ "$SCHV" -gt 123400 ]; then
								SRATP="n"
							fi
						fi
						SLBV=$(echo $QCAL | cut -d, -f6 | grep -o "[0-9]\{1,2\}")
						if [ -n "$SLBV" ]; then
							LBAND=$LBAND"<br />"$SRATP$SLBV
							BWD=$(echo $QCAL | cut -d, -f3 | grep -o "[0-9]\{1,3\}")
							if [ -n "$BWD" ]; then
								UPDOWN=$(echo $QCAL | cut -d, -f13)
								case "$UPDOWN" in
									"UL" )
										CATYPE="CA"$(printf "\xe2\x86\x91") ;;
									"DL" )
										CATYPE="CA"$(printf "\xe2\x86\x93") ;;
									* )
										CATYPE="CA" ;;
								esac
								if [ $BWD -gt 14 ]; then
									LBAND=$LBAND" ("$CATYPE", Bandwidth "$(($(echo $BWD) / 5))" MHz)"
								else
									LBAND=$LBAND" ("$CATYPE", Bandwidth 1.4 MHz)"
								fi
							fi
							LBAND=$LBAND
						fi
						PCI="$PCI, "$(echo $QCAL | cut -d, -f8)
					fi
				done
			fi
		fi
		if [ $RAT = "CAT-M" ] || [ $RAT = "CAT-NB" ]; then
			LBAND="B$(echo $QENG | cut -d, -f11) ($RAT)"
		fi
		;;
	"NR5G-SA")
		MODE="NR5G-SA"
		echo "0" > /tmp/modnetwork
		if [ -n "$QENG5" ]; then
			MODE="$RAT $(echo $QENG5 | cut -d, -f4)"
			PCI=$(echo $QENG5 | cut -d, -f8)
			CHANNEL=$(echo $QENG5 | cut -d, -f10)
			LBAND=$(echo $QENG5 | cut -d, -f11)
			PC_BAND="NR5G BAND "$LBAND
			BW=$(echo $QENG5 | cut -d, -f12)
			nr_bw
			LBAND="n"$LBAND" (Bandwidth $BW MHz)"
			RSCP=$(echo $QENG5 | cut -d, -f13)
			ECIO=$(echo $QENG5 | cut -d, -f14)
			if [ "$CSQ_PER" = "-" ]; then
                BW_N=($BW * 5)
                RSSI=$(rspr2rssi)
				CSQ_PER=$((100 - (($RSSI + 51) * 100/-62)))"%"
				CSQ=$((($RSSI + 113) / 2))
				CSQ_RSSI=$RSSI" dBm"
			fi
			SINRR=$(echo $QENG5 | cut -d, -f15 | grep -o "[0-9]\{1,3\}")
			if [ -n "$SINRR" ]; then
				if [ $SINRR -le 30 ]; then
					SINR=$((($(echo $SINRR) * 2) -20))" dB"
				fi
			fi
		fi
		;;
esac

QRSRP=$(echo "$OX" | grep -o "+QRSRP:[^,]\+,-[0-9]\{1,5\},-[0-9]\{1,5\},-[0-9]\{1,5\}[^ ]*")
if [ -n "$QRSRP" ] && [ "$RAT" != "WCDMA" ]; then
	QRSRP1=$(echo $QRSRP | cut -d, -f1 | grep -o "[-0-9]\+")
	QRSRP2=$(echo $QRSRP | cut -d, -f2)
	QRSRP3=$(echo $QRSRP | cut -d, -f3)
	QRSRP4=$(echo $QRSRP | cut -d, -f4)
	QRSRPtype=$(echo $QRSRP | cut -d, -f5)
	if [ "$QRSRPtype" == "NR5G" ]; then
		if [ -n "$NR_SA" ]; then
			RSCP=$QRSRP1
			if [ -n "$QRSRP2" -a "$QRSRP2" != "-32768" ]; then
				RSCP1="RxD "$QRSRP2
			fi
			if [ -n "$QRSRP3" -a "$QRSRP3" != "-32768" -a "$QRSRP3" != "-44" ]; then
				RSCP=$RSCP" dBm<br />"$QRSRP3
			fi
			if [ -n "$QRSRP4" -a "$QRSRP4" != "-32768" -a "$QRSRP4" != "-44" ]; then
				RSCP1="RxD "$QRSRP4
			fi
		else
			RSCP=$RSRPLTE
			if [ -n "$QRSRP1" -a "$QRSRP1" != "-32768" -a "$QRSRP1" != "-44" ]; then
				RSCP=$RSCP" (4G) dBm<br />"$QRSRP1
				if [ -n "$QRSRP2" -a "$QRSRP2" != "-32768" -a "$QRSRP2" != "-44" ]; then
					RSCP="$RSCP, $QRSRP2"
					if [ -n "$QRSRP3" -a "$QRSRP3" != "-32768" -a "$QRSRP3" != "-44" ]; then
						RSCP="$RSCP, $QRSRP3"
						if [ -n "$QRSRP4" -a "$QRSRP4" != "-32768" -a "$QRSRP4" != "-44" ]; then
							RSCP="$RSCP, $QRSRP4"
						fi
					fi
					RSCP=$RSCP" (5G) "
				fi
			fi
		fi
	elif [ "$QRSRP2$QRSRP3$QRSRP4" != "-44-44-44" -a -z "$QENG5" ]; then
		RSCP=$QRSRP1
		if [ "$QRSRP3$QRSRP4" == "-140-140" -o "$QRSRP3$QRSRP4" == "-44-44" -o "$QRSRP3$QRSRP4" == "-32768-32768" ]; then
			RSCP1="RxD "$(echo $QRSRP | cut -d, -f2)
		else
			RSCP=$RSCP" dBm (RxD "$QRSRP2" dBm)<br />"$QRSRP3
			RSCP1="RxD "$QRSRP4
		fi
	fi
fi

QNSM=$(echo "$QNSM" | grep -o "[0-9]")
if [ -n "$QNSM" ]; then
	MODTYPE="6"
	case $QNSM in
	"0" )
		NETMODE="1" ;;
	"1" )
		NETMODE="3" ;;
	"2"|"5" )
		NETMODE="5" ;;
	"3" )
		NETMODE="7" ;;
	esac
fi
if [ -n "$QNWP" ]; then
	MODTYPE="6"
	case $QNWP in
	"AUTO" )
		NETMODE="1" ;;
	"WCDMA" )
		NETMODE="5" ;;
	"LTE" )
		NETMODE="7" ;;
	"LTE:NR5G" )
		NETMODE="8" ;;
	"NR5G" )
		NETMODE="9" ;;
	esac
fi

OX=$(echo "${OX//[ \"]/}")

REGV=$(echo "$OX" | grep -o "+C5GREG:2,[0-9],[A-F0-9]\{2,6\},[A-F0-9]\{5,10\},[0-9]\{1,2\}")
if [ -n "$REGV" ]; then
	LAC5=$(echo "$REGV" | cut -d, -f3)
	LAC5=$LAC5" ($(printf "%d" 0x$LAC5))"
	CID5=$(echo "$REGV" | cut -d, -f4)
	CID5L=$(printf "%010X" 0x$CID5)
	RNC5=${CID5L:1:6}
	RNC5=$RNC5" ($(printf "%d" 0x$RNC5))"
	CID5=${CID5L:7:3}
	CID5="Short $(printf "%X" 0x$CID5) ($(printf "%d" 0x$CID5)), Long $(printf "%X" 0x$CID5L) ($(printf "%d" 0x$CID5L))"
	RAT=$(echo "$REGV" | cut -d, -f5)
fi
REGV=$(echo "$OX" | grep -o "+CEREG:2,[0-9],[A-F0-9]\{2,4\},[A-F0-9]\{5,8\}")
REGFMT="3GPP"
if [ -z "$REGV" ]; then
	REGV=$(echo "$OX" | grep -o "+CEREG:2,[0-9],[A-F0-9]\{2,4\},[A-F0-9]\{1,3\},[A-F0-9]\{5,8\}")
	REGFMT="SW"
fi
if [ -n "$REGV" ]; then
	LAC=$(echo "$REGV" | cut -d, -f3)
	LAC=$(printf "%04X" 0x$LAC)" ($(printf "%d" 0x$LAC))"
	if [ $REGFMT = "3GPP" ]; then
		CID=$(echo "$REGV" | cut -d, -f4)
	else
		CID=$(echo "$REGV" | cut -d, -f5)
	fi
	CIDL=$(printf "%08X" 0x$CID)
	RNC=${CIDL:1:5}
	RNC=$RNC" ($(printf "%d" 0x$RNC))"
	CID=${CIDL:6:2}
	CID="Short $(printf "%X" 0x$CID) ($(printf "%d" 0x$CID)), Long $(printf "%X" 0x$CIDL) ($(printf "%d" 0x$CIDL))"

else
	REGV=$(echo "$OX" | grep -o "+CREG:2,[0-9],[A-F0-9]\{2,4\},[A-F0-9]\{2,8\}")
	if [ -n "$REGV" ]; then
		LAC=$(echo "$REGV" | cut -d, -f3)
		CID=$(echo "$REGV" | cut -d, -f4)
		if [ ${#CID} -gt 4 ]; then
			LAC=$(printf "%04X" 0x$LAC)" ($(printf "%d" 0x$LAC))"
			CIDL=$(printf "%08X" 0x$CID)
			RNC=${CIDL:1:3}
			CID=${CIDL:4:4}
			CID="Short $(printf "%X" 0x$CID) ($(printf "%d" 0x$CID)), Long $(printf "%X" 0x$CIDL) ($(printf "%d" 0x$CIDL))"
		else
			LAC=""
		fi
	else
		LAC=""
	fi
fi
REGSTAT=$(echo "$REGV" | cut -d, -f2)
if [ "$REGSTAT" == "5" -a "$COPS" != "-" ]; then
	COPS_MNC=$COPS_MNC" (Roaming)"
fi
if [ -n "$CID" -a -n "$CID5" ] && [ "$RAT" == "13" -o "$RAT" == "10" ]; then
	LAC="4G $LAC, 5G $LAC5"
	CID="4G $CID<br />5G $CID5"
	RNC="4G $RNC, 5G $RNC5"
elif [ -n "$CID5" ]; then
	LAC=$LAC5
	CID=$CID5
	RNC=$RNC5
fi
if [ -z "$LAC" ]; then
	LAC="-"
	CID="-"
	RNC="-"
fi

LUPDATE=$(date +%s)
rm -fR /tmp/signal.txt
MODEZ=$(echo $MODE | tr -d '"')
{
	echo 'PROVIDER="'"$PROVIDER"'"'
	echo 'CSQ="'"$CSQ"'"'
	echo 'CSQ_PER="'"$CSQ_PER"'"'
	echo 'CSQ_RSSI="'"$CSQ_RSSI"'"'
	echo 'ECIO="'"$ECIO"'"'
	echo 'RSCP="'"$RSCP"'"'
	echo 'ECIO1="'"$ECIO1"'"'
	echo 'RSCP1="'"$RSCP1"'"'
	echo 'MODE="'"$MODEZ"'"'
	echo 'MODTYPE="'"$MODTYPE"'"'
	echo 'NETMODE="'"$NETMODE"'"'
	echo 'CHANNEL="'"$CHANNEL"'"'
	echo 'LBAND="'"$LBAND"'"'
	echo 'PC_BAND="'"$PC_BAND"'"'
	echo 'SC_BANDS="'"$SC_BANDS"'"'
	echo 'APN="'"$APN"'"'
	echo 'MODEM_MODEL="'"$MODEM_MODEL"'"'
	echo 'SIMSLOT="'"$SIMSLOT"'"'
	echo 'PCI="'"$PCI"'"'
	echo 'TEMP="'"$CTEMP"'"'
	echo 'SINR="'"$SINR"'"'
	echo 'LASTUPDATE="'"$LUPDATE"'"'
	echo 'COPS="'"$COPS"'"'
	echo 'COPS_MCC="'"$COPS_MCC"'"'
	echo 'COPS_MNC="'"$COPS_MNC"'"'
	echo 'MCCMNC="'"$MCCMNC"'"'
	echo 'LAC="'"$LAC"'"'
	echo 'LAC_NUM="'""'"'
	echo 'CID="'"$CID"'"'
	echo 'CID_NUM="'""'"'
	echo 'RNC="'"$RNC"'"'
	echo 'RNC_NUM="'""'"'
}  > /tmp/signal.txt

# Pregenerate JSON File
/usrdata/simpleadmin/scripts/tojson.sh /tmp/signal.txt > /tmp/modemstatus.json