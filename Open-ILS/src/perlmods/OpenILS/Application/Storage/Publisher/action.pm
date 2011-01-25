package OpenILS::Application::Storage::Publisher::action;
use base qw/OpenILS::Application::Storage::Publisher/;
use OpenSRF::Utils::Logger qw/:level/;
use OpenSRF::Utils qw/:datetime/;
use OpenSRF::AppSession;
use OpenSRF::EX qw/:try/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::PermitHold;
use DateTime;
use DateTime::Format::ISO8601;
use OpenILS::Utils::Penalty;

sub isTrue {
	my $v = shift;
	return 1 if ($v == 1);
	return 1 if ($v =~ /^t/io);
	return 1 if ($v =~ /^y/io);
	return 0;
}

my $parser = DateTime::Format::ISO8601->new;
my $log = 'OpenSRF::Utils::Logger';

sub open_noncat_circs {
	my $self = shift;
	my $client = shift;
	my $user = shift;

	my $a = action::non_cataloged_circulation->table;
	my $c = config::non_cataloged_type->table;

	my $sql = <<"	SQL";
		SELECT	a.id
		  FROM	$a a
			JOIN $c c ON (a.item_type = c.id)
		  WHERE	a.circ_time + c.circ_duration > current_timestamp
			AND a.patron = ?
	SQL

	return action::non_cataloged_circulation->db_Main->selectcol_arrayref($sql, {}, $user);
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.open_non_cataloged_circulation.user',
	api_level       => 1,
	argc		=> 1,
	method          => 'open_noncat_circs',
);


sub ou_hold_requests {
	my $self = shift;
	my $client = shift;
	my $ou = shift;

	my $h_table = action::hold_request->table;
	my $c_table = asset::copy->table;
	my $o_table = actor::org_unit->table;

	my $SQL = <<"	SQL";
		SELECT 	h.id
		  FROM	$h_table h
		  	JOIN $c_table cp ON (cp.id = h.current_copy)
			JOIN $o_table ou ON (ou.id = cp.circ_lib)
		  WHERE	ou.id = ?
		  	AND h.capture_time IS NULL
		  	AND h.cancel_time IS NULL
		  	AND (h.expire_time IS NULL OR h.expire_time > NOW())
		  ORDER BY h.request_time
	SQL

	my $sth = action::hold_request->db_Main->prepare_cached($SQL);
	$sth->execute($ou);

	$client->respond($_) for (
		map {
			$self
				->method_lookup('open-ils.storage.direct.action.hold_request.retrieve')
				->run($_)
		} map {
			$_->[0]
		} @{ $sth->fetchall_arrayref }
	);
	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.targeted_hold_request.org_unit',
	api_level       => 1,
	argc		=> 1,
	stream		=> 1,
	method          => 'ou_hold_requests',
);


sub overdue_circs {
	my $grace = shift;
    my $upper_interval = shift || '1 millennium';

	my $c_t = action::circulation->table;

	if ($grace && $grace =~ /^\d+$/o) {
    	$grace = " - ($grace * (fine_interval))";
    } else {
        $grace = '';
    } 

	my $sql = <<"	SQL";
		SELECT	*
		  FROM	$c_t
		  WHERE	stop_fines IS NULL
		  	AND due_date < ( CURRENT_TIMESTAMP $grace)
            AND fine_interval < ?::INTERVAL
	SQL

	my $sth = action::circulation->db_Main->prepare_cached($sql);
	$sth->execute($upper_interval);

	my @circs = map { action::circulation->construct($_) } $sth->fetchall_hash;

	$c_t = booking::reservation->table;
	$sql = <<"	SQL";
		SELECT	*
		  FROM	$c_t
		  WHERE	return_time IS NULL
		  	AND end_time < ( CURRENT_TIMESTAMP $grace)
            AND fine_interval IS NOT NULL
            AND cancel_time IS NULL
	SQL

	$sth = action::circulation->db_Main->prepare_cached($sql);
	$sth->execute();

    push @circs, map { booking::reservation->construct($_) } $sth->fetchall_hash;

    return @circs;
}

sub complete_reshelving {
	my $self = shift;
	my $client = shift;
	my $window = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	throw OpenSRF::EX::InvalidArg ("I need an interval of more than 0 seconds!")
		unless (interval_to_seconds( $window ));

	my $setting = actor::org_unit_setting->table;
	my $circ = action::circulation->table;
	my $cp = asset::copy->table;
	my $atc = action::transit_copy->table;

	my $sql = <<"	SQL";
		UPDATE	$cp
		  SET	status = 0
		  WHERE	id IN (
			SELECT  id
			  FROM  (SELECT cp.id, MAX(circ.checkin_time), MAX(trans.dest_recv_time)
					  FROM  $cp cp
							JOIN $circ circ ON (circ.target_copy = cp.id)
							LEFT JOIN $atc trans ON (trans.target_copy = cp.id)
							LEFT JOIN $setting setting
								ON (cp.circ_lib = setting.org_unit AND setting.name = 'circ.reshelving_complete.interval')
					  WHERE circ.checkin_time IS NOT NULL
							AND cp.status = 7
					  GROUP BY 1
					  HAVING (
						( ( MAX(circ.checkin_time) > MAX(trans.dest_recv_time) or MAX(trans.dest_recv_time) IS NULL )
						  AND MAX(circ.checkin_time) < NOW() - CAST( COALESCE( BTRIM( FIRST(setting.value),'"' ), ? )  AS INTERVAL) )
						OR
						( MAX(trans.dest_recv_time) > MAX(circ.checkin_time)
						  AND MAX(trans.dest_recv_time) < NOW() - CAST( COALESCE( BTRIM( FIRST(setting.value),'"' ), ? )  AS INTERVAL) )
					  )
					) AS foo
								UNION ALL
			SELECT  cp.id
			  FROM  $cp cp 
					LEFT JOIN $setting setting
						ON (cp.circ_lib = setting.org_unit AND setting.name = 'circ.reshelving_complete.interval')
					LEFT JOIN $circ circ ON (circ.target_copy = cp.id)
			  WHERE cp.status = 7
					AND circ.id IS NULL
					AND cp.create_date < NOW() - CAST( COALESCE( BTRIM( setting.value,'"' ), ? )  AS INTERVAL)
		  )
	SQL
	my $sth = action::circulation->db_Main->prepare_cached($sql);
	$sth->execute($window, $window, $window);

	return $sth->rows;

}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.circulation.reshelving.complete',
	api_level       => 1,
	argc		=> 1,
	method          => 'complete_reshelving',
);

sub mark_longoverdue {
	my $self = shift;
	my $client = shift;
	my $window = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	throw OpenSRF::EX::InvalidArg ("I need an interval of more than 0 seconds!")
		unless (interval_to_seconds( $window ));

	my $setting = actor::org_unit_setting->table;
	my $circ = action::circulation->table;

	my $sql = <<"	SQL";
		UPDATE	$circ
		  SET	stop_fines = 'LONGOVERDUE',
			stop_fines_time = now()
		  WHERE	id IN (
		    SELECT  circ.id
                      FROM  $circ circ
                            LEFT JOIN $setting setting
                                ON (circ.circ_lib = setting.org_unit AND setting.name = 'circ.long_overdue.interval')
                      WHERE circ.checkin_time IS NULL AND (stop_fines IS NULL OR stop_fines NOT IN ('LOST','LONGOVERDUE'))
                            AND AGE(circ.due_date) > CAST( COALESCE( BTRIM( setting.value,'"' ), ? )  AS INTERVAL)
                  )
	SQL

	my $sth = action::circulation->db_Main->prepare_cached($sql);
	$sth->execute($window);

	return $sth->rows;

}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.circulation.long_overdue',
	api_level       => 1,
	argc		=> 1,
	method          => 'mark_longoverdue',
);

sub auto_thaw_frozen_holds {
	my $self = shift;
	my $client = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	my $holds = action::hold_request->table;

	my $sql = "UPDATE $holds SET frozen = FALSE WHERE frozen IS TRUE AND thaw_date < NOW();";

	my $sth = action::hold_request->db_Main->prepare_cached($sql);
	$sth->execute();

	return $sth->rows;

}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.hold_request.thaw_expired_frozen',
	api_level       => 1,
	stream		=> 0,
	argc		=> 0,
	method          => 'auto_thaw_frozen_holds',
);

sub grab_overdue {
	my $self = shift;
	my $client = shift;
	my $grace = shift || '';

	$client->respond( $_->to_fieldmapper ) for ( overdue_circs($grace) );

	return undef;

}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.circulation.overdue',
	api_level       => 1,
	stream		=> 1,
	method          => 'grab_overdue',
);

sub nearest_hold {
	my $self = shift;
	my $client = shift;
	my $here = shift;
	my $cp = shift;
	my $limit = int(shift()) || 10;
	my $age = shift() || '0 seconds';
    my $fifo = shift();

    my $holdsort = $fifo ? "h.request_time, h.selection_depth DESC, p.prox " : "p.prox, h.selection_depth DESC, h.request_time ";

	my $ids = action::hold_request->db_Main->selectcol_arrayref(<<"	SQL", {}, $here, $cp, $age);
		SELECT	h.id
		  FROM	action.hold_request h
			JOIN actor.org_unit_proximity p ON (p.from_org = ? AND p.to_org = h.pickup_lib)
		  	JOIN action.hold_copy_map hm ON (hm.hold = h.id)
		  WHERE hm.target_copy = ?
		  	AND (AGE(NOW(),h.request_time) >= CAST(? AS INTERVAL) OR p.prox = 0)
			AND h.capture_time IS NULL
		  	AND h.cancel_time IS NULL
		  	AND (h.expire_time IS NULL OR h.expire_time > NOW())
            AND h.frozen IS FALSE
		ORDER BY $holdsort
		LIMIT $limit
	SQL
	
	$client->respond( $_ ) for ( @$ids );
	return undef;
}
__PACKAGE__->register_method(
	api_name	=> 'open-ils.storage.action.hold_request.nearest_hold',
	api_level	=> 1,
	stream		=> 1,
	method		=> 'nearest_hold',
);

sub next_resp_group_id {
	my $self = shift;
	my $client = shift;

	# XXX This is not replication safe!!!

	my ($id) = action::survey->db_Main->selectrow_array(<<"	SQL");
		SELECT NEXTVAL('action.survey_response_group_id_seq'::TEXT)
	SQL
	return $id;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey_response.next_group_id',
	api_level       => 1,
	method          => 'next_resp_group_id',
);

sub patron_circ_summary {
	my $self = shift;
	my $client = shift;
	my $id = ''.shift();

	return undef unless ($id);
	my $c_table = action::circulation->table;
	my $b_table = money::billing->table;

	$log->debug("Retrieving patron summary for id $id", DEBUG);

	my $select = <<"	SQL";
		SELECT	COUNT(DISTINCT c.id), SUM( COALESCE(b.amount,0) )
		  FROM	$c_table c
		  	LEFT OUTER JOIN $b_table b ON (c.id = b.xact AND b.voided = FALSE)
		  WHERE	c.usr = ?
		  	AND c.xact_finish IS NULL
			AND (
				c.stop_fines NOT IN ('CLAIMSRETURNED','LOST')
				OR c.stop_fines IS NULL
			)
	SQL

	return action::survey->db_Main->selectrow_arrayref($select, {}, $id);
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.circulation.patron_summary',
	api_level       => 1,
	method          => 'patron_circ_summary',
);

#XXX Fix stored proc calls
sub find_local_surveys {
	my $self = shift;
	my $client = shift;
	my $ou = ''.shift();

	return undef unless ($ou);
	my $s_table = action::survey->table;

	my $select = <<"	SQL";
		SELECT	s.*
		  FROM	$s_table s
		  	JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
		  WHERE	CURRENT_TIMESTAMP BETWEEN s.start_date AND s.end_date
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	$client->respond( $_->to_fieldmapper ) for ( map { action::survey->construct($_) } $sth->fetchall_hash );

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey.all',
	api_level       => 1,
	stream          => 1,
	method          => 'find_local_surveys',
);

#XXX Fix stored proc calls
sub find_opac_surveys {
	my $self = shift;
	my $client = shift;
	my $ou = ''.shift();

	return undef unless ($ou);
	my $s_table = action::survey->table;

	my $select = <<"	SQL";
		SELECT	s.*
		  FROM	$s_table s
		  	JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
		  WHERE	CURRENT_TIMESTAMP BETWEEN s.start_date AND s.end_date
		  	AND s.opac IS TRUE;
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	$client->respond( $_->to_fieldmapper ) for ( map { action::survey->construct($_) } $sth->fetchall_hash );

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey.opac',
	api_level       => 1,
	stream          => 1,
	method          => 'find_opac_surveys',
);

sub hold_pull_list {
	my $self = shift;
	my $client = shift;
	my $ou = shift;
	my $limit = shift || 10;
	my $offset = shift || 0;

	return undef unless ($ou);
	my $h_table = action::hold_request->table;
	my $a_table = asset::copy->table;

	my $idlist = 1 if ($self->api_name =~/id_list/o);

	my $status_filter = '';
	$status_filter = 'AND a.status IN (0,7)' if ($self->api_name =~/status_filtered/o);

	my $select = <<"	SQL";
		SELECT	h.*
		  FROM	$h_table h
		  	JOIN $a_table a ON (h.current_copy = a.id)
		  WHERE	a.circ_lib = ?
		  	AND h.capture_time IS NULL
		  	AND h.cancel_time IS NULL
		  	AND (h.expire_time IS NULL OR h.expire_time > NOW())
			$status_filter
		  ORDER BY h.request_time ASC
		  LIMIT $limit
		  OFFSET $offset
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	if ($idlist) {
		$client->respond( $_->{id} ) for ( $sth->fetchall_hash );
	} else {
		$client->respond( $_->to_fieldmapper ) for ( map { action::hold_request->construct($_) } $sth->fetchall_hash );
	}

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.direct.action.hold_request.pull_list.id_list.current_copy_circ_lib',
	api_level       => 1,
	stream          => 1,
	signature	=> [
		"Returns the hold ids for a specific library's pull list.",
 		[ [org_unit => "The library's org id", "number"],
		  [limit => 'An optional page size, defaults to 10', 'number'],
		  [offset => 'Offset for paging, defaults to 0, 0 based', 'number'],
		],
		['A list of holds for the stated library to pull for', 'array']
	],
	method          => 'hold_pull_list',
);
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.direct.action.hold_request.pull_list.search.current_copy_circ_lib',
	api_level       => 1,
	stream          => 1,
	signature	=> [
		"Returns the holds for a specific library's pull list.",
 		[ [org_unit => "The library's org id", "number"],
		  [limit => 'An optional page size, defaults to 10', 'number'],
		  [offset => 'Offset for paging, defaults to 0, 0 based', 'number'],
		],
		['A list of holds for the stated library to pull for', 'array']
	],
	method          => 'hold_pull_list',
);
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.direct.action.hold_request.pull_list.id_list.current_copy_circ_lib.status_filtered',
	api_level       => 1,
	stream          => 1,
	signature	=> [
		"Returns the hold ids for a specific library's pull list that are definitely in that library, based on status.",
 		[ [org_unit => "The library's org id", "number"],
		  [limit => 'An optional page size, defaults to 10', 'number'],
		  [offset => 'Offset for paging, defaults to 0, 0 based', 'number'],
		],
		['A list of holds for the stated library to pull for', 'array']
	],
	method          => 'hold_pull_list',
);
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.direct.action.hold_request.pull_list.search.current_copy_circ_lib.status_filtered',
	api_level       => 1,
	stream          => 1,
	signature	=> [
		"Returns the holds for a specific library's pull list that are definitely in that library, based on status.",
 		[ [org_unit => "The library's org id", "number"],
		  [limit => 'An optional page size, defaults to 10', 'number'],
		  [offset => 'Offset for paging, defaults to 0, 0 based', 'number'],
		],
		['A list of holds for the stated library to pull for', 'array']
	],
	method          => 'hold_pull_list',
);

sub find_optional_surveys {
	my $self = shift;
	my $client = shift;
	my $ou = ''.shift();

	return undef unless ($ou);
	my $s_table = action::survey->table;

	my $select = <<"	SQL";
		SELECT	s.*
		  FROM	$s_table s
		  	JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
		  WHERE	CURRENT_TIMESTAMP BETWEEN s.start_date AND s.end_date
		  	AND s.required IS FALSE;
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	$client->respond( $_->to_fieldmapper ) for ( map { action::survey->construct($_) } $sth->fetchall_hash );

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey.optional',
	api_level       => 1,
	stream          => 1,
	method          => 'find_optional_surveys',
);

sub find_required_surveys {
	my $self = shift;
	my $client = shift;
	my $ou = ''.shift();

	return undef unless ($ou);
	my $s_table = action::survey->table;

	my $select = <<"	SQL";
		SELECT	s.*
		  FROM	$s_table s
		  	JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
		  WHERE	CURRENT_TIMESTAMP BETWEEN s.start_date AND s.end_date
		  	AND s.required IS TRUE;
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	$client->respond( $_->to_fieldmapper ) for ( map { action::survey->construct($_) } $sth->fetchall_hash );

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey.required',
	api_level       => 1,
	stream          => 1,
	method          => 'find_required_surveys',
);

sub find_usr_summary_surveys {
	my $self = shift;
	my $client = shift;
	my $ou = ''.shift();

	return undef unless ($ou);
	my $s_table = action::survey->table;

	my $select = <<"	SQL";
		SELECT	s.*
		  FROM	$s_table s
		  	JOIN actor.org_unit_full_path(?) p ON (p.id = s.owner)
		  WHERE	CURRENT_TIMESTAMP BETWEEN s.start_date AND s.end_date
		  	AND s.usr_summary IS TRUE;
	SQL

	my $sth = action::survey->db_Main->prepare_cached($select);
	$sth->execute($ou);

	$client->respond( $_->to_fieldmapper ) for ( map { action::survey->construct($_) } $sth->fetchall_hash );

	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.survey.usr_summary',
	api_level       => 1,
	stream          => 1,
	method          => 'find_usr_summary_surveys',
);

sub seconds_to_interval_hash {
		my $interval = shift;
		my $limit = shift || 's';
		$limit =~ s/^(.)/$1/o;

		my %output;

		my ($y,$ym,$M,$Mm,$w,$wm,$d,$dm,$h,$hm,$m,$mm,$s);
		my ($year, $month, $week, $day, $hour, $minute, $second) =
				('years','months','weeks','days', 'hours', 'minutes', 'seconds');

		if ($y = int($interval / (60 * 60 * 24 * 365))) {
				$output{$year} = $y;
				$ym = $interval % (60 * 60 * 24 * 365);
		} else {
				$ym = $interval;
		}
		return %output if ($limit eq 'y');

		if ($M = int($ym / ((60 * 60 * 24 * 365)/12))) {
				$output{$month} = $M;
				$Mm = $ym % ((60 * 60 * 24 * 365)/12);
		} else {
				$Mm = $ym;
		}
		return %output if ($limit eq 'M');

		if ($w = int($Mm / 604800)) {
				$output{$week} = $w;
				$wm = $Mm % 604800;
		} else {
				$wm = $Mm;
		}
		return %output if ($limit eq 'w');

		if ($d = int($wm / 86400)) {
				$output{$day} = $d;
				$dm = $wm % 86400;
		} else {
				$dm = $wm;
		}
		return %output if ($limit eq 'd');

		if ($h = int($dm / 3600)) {
				$output{$hour} = $h;
				$hm = $dm % 3600;
		} else {
				$hm = $dm;
		}
		return %output if ($limit eq 'h');

		if ($m = int($hm / 60)) {
				$output{$minute} = $m;
				$mm = $hm % 60;
		} else {
				$mm = $hm;
		}
		return %output if ($limit eq 'm');

		if ($s = int($mm)) {
				$output{$second} = $s;
		} else {
				$output{$second} = 0 unless (keys %output);
		}
		return %output;
}


sub generate_fines {
	my $self = shift;
	my $client = shift;
	my $grace = shift;
	my $circ = shift;
	my $overbill = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	my @circs;
	if ($circ) {
		push @circs,
            action::circulation->search_where( { id => $circ, stop_fines => undef } ),
            booking::reservation->search_where( { id => $circ, return_time => undef, cancel_time => undef } );
	} else {
		push @circs, overdue_circs($grace);
	}

	my %hoo = map { ( $_->id => $_ ) } actor::org_unit::hours_of_operation->retrieve_all;

	my $penalty = OpenSRF::AppSession->create('open-ils.penalty');
	for my $c (@circs) {

        my $ctype = ref($c);
        $ctype =~ s/^.+::(\w+)$/$1/;
	
        my $due_date_method = 'due_date';
        my $target_copy_method = 'target_copy';
        my $circ_lib_method = 'circ_lib';
        my $recurring_fine_method = 'recuring_fine';
        my $is_reservation = 0;
        if ($ctype eq 'reservation') {
            $is_reservation = 1;
            $due_date_method = 'end_time';
            $target_copy_method = 'current_resource';
            $circ_lib_method = 'pickup_lib';
            $recurring_fine_method = 'fine_amount';
            next unless ($c->fine_interval);
        }

		try {
			if ($self->method_lookup('open-ils.storage.transaction.current')->run) {
				$log->debug("Cleaning up after previous transaction\n");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			}
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$log->info(
				sprintf("Processing %s %d...",
					($is_reservation ? "reservation" : "circ"), $c->id
				)
			);

			my $due_dt = $parser->parse_datetime( clense_ISO8601( $c->$due_date_method ) );
	
			my $due = $due_dt->epoch;
			my $now = time;

			my $fine_interval = $c->fine_interval;
            $fine_interval =~ s/(\d{2}):(\d{2}):(\d{2})/$1 h $2 m $3 s/o;
			$fine_interval = interval_to_seconds( $fine_interval );
	
			if ( $is_reservation and $fine_interval >= interval_to_seconds('1d') ) {	
				my $tz_offset_s = 0;
				if ($due_dt->strftime('%z') =~ /(-|\+)(\d{2}):?(\d{2})/) {
					$tz_offset_s = $1 . interval_to_seconds( "${2}h ${3}m"); 
				}
	
				$due -= ($due % $fine_interval) + $tz_offset_s;
				$now -= ($now % $fine_interval) + $tz_offset_s;
			}
	
			$client->respond(
				"ARG! Overdue $ctype ".$c->id.
				" for item ".$c->$target_copy_method.
				" (user ".$c->usr.").\n".
				"\tItem was due on or before: ".localtime($due)."\n");
	
			my @fines = money::billing->search_where(
				{ xact => $c->id,
				  btype => 1,
				  billing_ts => { '>' => $c->$due_date_method } },
				{ order_by => 'billing_ts DESC'}
			);

			my $f_idx = 0;
			my $fine = $fines[$f_idx] if (@fines);
			if ($overbill) {
				$fine = $fines[++$f_idx] while ($fine and $fine->voided);
			}

			my $current_fine_total = 0;
			$current_fine_total += int($_->amount * 100) for (grep { $_ and !$_->voided } @fines);
	
			my $last_fine;
			if ($fine) {
				$client->respond( "Last billing time: ".$fine->billing_ts." (clensed fromat: ".clense_ISO8601( $fine->billing_ts ).")");
				$last_fine = $parser->parse_datetime( clense_ISO8601( $fine->billing_ts ) )->epoch;
			} else {
				$log->info( "Potential first billing for circ ".$c->id );
				$last_fine = $due;

				if (0) {
					if (my $h = $hoo{$c->$circ_lib_method}) { 

						$log->info( "Circ lib has an hours-of-operation entry" );
						# find the day after the due date...
						$due_dt = $due_dt->add( days => 1 );

						# get the day of the week for that day...
						my $dow = $due_dt->day_of_week_0;
						my $dow_open = "dow_${dow}_open";
						my $dow_close = "dow_${dow}_close";

						my $count = 0;
						while ( $h->$dow_open eq '00:00:00' and $h->$dow_close eq '00:00:00' ) {
							# if the circ lib is closed, add a day to the grace period...

							$grace++;
							$log->info( "Grace period for circ ".$c->id." extended to $grace intervals" );
							$log->info( "Day of week $dow open $dow_open, close $dow_close" );

							$due_dt = $due_dt->add( days => 1 );
							$dow = $due_dt->day_of_week_0;
							$dow_open = "dow_${dow}_open";
							$dow_close = "dow_${dow}_close";

							$count++;

							# and check for up to a week
							last if ($count > 6);
						}
					}
				}
			}

            next if ($last_fine > $now);
            my $pending_fine_count = int( ($now - $last_fine) / $fine_interval ); 

            # Generate fines for the interval we are currently inside, when the fine interval is some multiple of 1d
            $pending_fine_count++ if ($fine_interval && ($fine_interval % 86400 == 0));

            if ( $last_fine == $due                         # we have no fines yet
                 && $grace                                  # and we have a grace period
                 && $pending_fine_count <= $grace           # and we seem to be inside that period
                 && $now < $due + $fine_interval * $grace   # and some date math bares that out, then
            ) {
                $client->respond( "Still inside grace period of: ". seconds_to_interval( $fine_interval * $grace)."\n" );
                $log->info( "Circ ".$c->id." is still inside grace period of: $grace [". seconds_to_interval( $fine_interval * $grace).']' );
                next;
            }

            $client->respond( "\t$pending_fine_count pending fine(s)\n" );
            next unless ($pending_fine_count);

			my $recuring_fine = int($c->$recurring_fine_method * 100);
			my $max_fine = int($c->max_fine * 100);

			my ($latest_billing_ts, $latest_amount) = ('',0);
			for (my $bill = 1; $bill <= $pending_fine_count; $bill++) {
	
				if ($current_fine_total >= $max_fine) {
					$c->update({stop_fines => 'MAXFINES', stop_fines_time => 'now'}) if ($ctype eq 'circulation');
					$client->respond(
						"\tMaximum fine level of ".$c->max_fine.
						" reached for this $ctype.\n".
						"\tNo more fines will be generated.\n" );
					last;
				}
				
				# XXX Use org time zone (or default to 'local') once we have the ou setting built for that
				my $billing_ts = DateTime->from_epoch( epoch => $last_fine, time_zone => 'local' );
				my $current_bill_count = $bill;
				while ( $current_bill_count ) {
					$billing_ts->add( seconds_to_interval_hash( $fine_interval ) );
					$current_bill_count--;
				}

				my $dow = $billing_ts->day_of_week_0();
				my $dow_open = "dow_${dow}_open";
				my $dow_close = "dow_${dow}_close";

				if (my $h = $hoo{$c->$circ_lib_method}) {
					next if ( $h->$dow_open eq '00:00:00' and $h->$dow_close eq '00:00:00');
				}

				my $timestamptz = $billing_ts->strftime('%FT%T%z');
				my @cl = actor::org_unit::closed_date->search_where(
						{ close_start	=> { '<=' => $timestamptz },
						  close_end	=> { '>=' => $timestamptz },
						  org_unit	=> $c->$circ_lib_method }
				);
				next if (@cl);
	
				$current_fine_total += $recuring_fine;
				$latest_amount += $recuring_fine;
				$latest_billing_ts = $timestamptz;

				money::billing->create(
					{ xact		=> ''.$c->id,
					  note		=> "System Generated Overdue Fine",
					  billing_type	=> "Overdue materials",
					  btype		=> 1,
					  amount	=> sprintf('%0.2f', $recuring_fine/100),
					  billing_ts	=> $timestamptz,
					}
				);

			}

			$client->respond( "\t\tAdding fines totaling $latest_amount for overdue up to $latest_billing_ts\n" )
				if ($latest_billing_ts and $latest_amount);

			$self->method_lookup('open-ils.storage.transaction.commit')->run;

			if(1) { 

                # Caluclate penalties inline
				OpenILS::Utils::Penalty->calculate_penalties(
					undef, $c->usr->to_fieldmapper->id.'', $c->$circ_lib_method->to_fieldmapper->id.'');

			} else {

                # Calculate penalties with an aysnc call to the penalty server.  This approach
                # may lead to duplicate penalties since multiple penalty processes for a
                # given user may be running at the same time. Leave this here for reference 
                # in case we later find that asyc calls are needed in some environments.
				$penalty->request(
				    'open-ils.penalty.patron_penalty.calculate',
				    { patronid	=> ''.$c->usr,
				    context_org	=> ''.$c->$circ_lib_method,
				    update	=> 1,
				    background	=> 1,
				    }
			    )->gather(1);
            }

		} catch Error with {
			my $e = shift;
			$client->respond( "Error processing overdue $ctype [".$c->id."]:\n\n$e\n" );
			$log->error("Error processing overdue $ctype [".$c->id."]:\n$e\n");
			$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			throw $e if ($e =~ /IS NOT CONNECTED TO THE NETWORK/o);
		};
	}
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.circulation.overdue.generate_fines',
	api_level       => 1,
	stream		=> 1,
	method          => 'generate_fines',
);



sub new_hold_copy_targeter {
	my $self = shift;
	my $client = shift;
	my $check_expire = shift;
	my $one_hold = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	my $holds;

	try {
		if ($one_hold) {
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$holds = [ action::hold_request->search_where( { id => $one_hold, fulfillment_time => undef, cancel_time => undef } ) ];
		} elsif ( $check_expire ) {

			# what's the retarget time threashold?
			my $time = time;
			$check_expire ||= '12h';
			$check_expire = interval_to_seconds( $check_expire );

			my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time() - $check_expire);
			$year += 1900;
			$mon += 1;
			my $expire_threshold = sprintf(
				'%s-%0.2d-%0.2dT%0.2d:%0.2d:%0.2d-00',
				$year, $mon, $mday, $hour, $min, $sec
			);

			# find all the holds holds needing retargeting
			$holds = [ action::hold_request->search_where(
							{ capture_time => undef,
							  fulfillment_time => undef,
							  cancel_time => undef,
							  frozen => 'f',
							  prev_check_time => { '<=' => $expire_threshold },
							},
							{ order_by => 'CASE WHEN hold_type = \'F\' THEN 0 ELSE 1 END, selection_depth DESC, request_time,prev_check_time' } ) ];

			# find all the holds holds needing first time targeting
			push @$holds, action::hold_request->search(
							capture_time => undef,
							fulfillment_time => undef,
				  			prev_check_time => undef,
							frozen => 'f',
							cancel_time => undef,
							{ order_by => 'CASE WHEN hold_type = \'F\' THEN 0 ELSE 1 END, selection_depth DESC, request_time' } );
		} else {

			# find all the holds holds needing first time targeting ONLY
			$holds = [ action::hold_request->search(
							capture_time => undef,
							fulfillment_time => undef,
				  			prev_check_time => undef,
							cancel_time => undef,
							frozen => 'f',
							{ order_by => 'CASE WHEN hold_type = \'F\' THEN 0 ELSE 1 END, selection_depth DESC, request_time' } ) ];
		}
	} catch Error with {
		my $e = shift;
		die "Could not retrieve uncaptured hold requests:\n\n$e\n";
	};

	my @closed = actor::org_unit::closed_date->search_where(
		{ close_start => { '<=', 'now' },
		  close_end => { '>=', 'now' } }
	);


	my @successes;

	for my $hold (@$holds) {
		try {
			#start a transaction if needed
			if ($self->method_lookup('open-ils.storage.transaction.current')->run) {
				$log->debug("Cleaning up after previous transaction\n");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			}
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$log->info("Processing hold ".$hold->id."...\n");

			#first, re-fetch the hold, to make sure it's not captured already
			$hold->remove_from_object_index();
			$hold = action::hold_request->retrieve( $hold->id );

			die "OK\n" if (!$hold or $hold->capture_time or $hold->cancel_time);

			# remove old auto-targeting maps
			my @oldmaps = action::hold_copy_map->search( hold => $hold->id );
			$_->delete for (@oldmaps);

			if ($hold->expire_time) {
				my $ex_time = $parser->parse_datetime( clense_ISO8601( $hold->expire_time ) );
				if ( DateTime->compare($ex_time, DateTime->now) < 0 ) {
					$hold->update( { cancel_time => 'now' } );
					$self->method_lookup('open-ils.storage.transaction.commit')->run;
					die "OK\n";
				}
			}

			my $all_copies = [];

			# find filters for MR holds
			my ($types, $formats, $lang) = split '-', $hold->holdable_formats;

			# find all the potential copies
			if ($hold->hold_type eq 'M') {
				for my $r ( map
						{$_->record}
						metabib::record_descriptor
							->search(
								record => [
									map {
										isTrue($_->deleted) ?  () : ($_->id)
									} metabib::metarecord->retrieve($hold->target)->source_records
								],
								( $types   ? (item_type => [split '', $types])   : () ),
								( $formats ? (item_form => [split '', $formats]) : () ),
								( $lang    ? (item_lang => $lang)                : () ),
							)
				) {
					my ($rtree) = $self
						->method_lookup( 'open-ils.storage.biblio.record_entry.ranged_tree')
						->run( $r->id, $hold->selection_ou, $hold->selection_depth );

					for my $cn ( @{ $rtree->call_numbers } ) {
						push @$all_copies,
							asset::copy->search_where(
								{ id => [map {$_->id} @{ $cn->copies }],
								  deleted => 'f' }
							) if ($cn && @{ $cn->copies });
					}
				}
			} elsif ($hold->hold_type eq 'T') {
				my ($rtree) = $self
					->method_lookup( 'open-ils.storage.biblio.record_entry.ranged_tree')
					->run( $hold->target, $hold->selection_ou, $hold->selection_depth );

				unless ($rtree) {
					push @successes, { hold => $hold->id, eligible_copies => 0, error => 'NO_RECORD' };
					die "OK\n";
				}

				for my $cn ( @{ $rtree->call_numbers } ) {
					push @$all_copies,
						asset::copy->search_where(
							{ id => [map {$_->id} @{ $cn->copies }],
							  deleted => 'f' }
						) if ($cn && @{ $cn->copies });
				}
			} elsif ($hold->hold_type eq 'V') {
				my ($vtree) = $self
					->method_lookup( 'open-ils.storage.asset.call_number.ranged_tree')
					->run( $hold->target, $hold->selection_ou, $hold->selection_depth );

				push @$all_copies,
					asset::copy->search_where(
						{ id => [map {$_->id} @{ $vtree->copies }],
						  deleted => 'f' }
					) if ($vtree && @{ $vtree->copies });
					
			} elsif  ($hold->hold_type eq 'C' || $hold->hold_type eq 'R' || $hold->hold_type eq 'F') {
				my $_cp = asset::copy->retrieve($hold->target);
				push @$all_copies, $_cp if $_cp;
			}

			# trim unholdables
			@$all_copies = grep {	isTrue($_->status->holdable) && 
						isTrue($_->location->holdable) && 
						isTrue($_->holdable) &&
						!isTrue($_->deleted)
					} @$all_copies;

			# let 'em know we're still working
			$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			
			# if we have no copies ...
			if (!ref $all_copies || !@$all_copies) {
				$log->info("\tNo copies available for targeting at all!\n");
				push @successes, { hold => $hold->id, eligible_copies => 0, error => 'NO_COPIES' };

				$hold->update( { prev_check_time => 'today', current_copy => undef } );
				$self->method_lookup('open-ils.storage.transaction.commit')->run;
				die "OK\n";
			}

			my $copy_count = @$all_copies;

			# map the potentials, so that we can pick up checkins
			$log->debug( "\tMapping ".scalar(@$all_copies)." potential copies for hold ".$hold->id);
			action::hold_copy_map->create( { hold => $hold->id, target_copy => $_->id } ) for (@$all_copies);

			#$client->status( new OpenSRF::DomainObject::oilsContinueStatus );

			my @good_copies;
			for my $c (@$all_copies) {
				# current target
				next if ($c->id eq $hold->current_copy);

				# circ lib is closed
				next if ( grep { ''.$_->org_unit eq ''.$c->circ_lib } @closed );

				# target of another hold
				next if (action::hold_request
						->search_where(
							{ current_copy => $c->id,
							  fulfillment_time => undef,
							  cancel_time => undef,
							}
						)
				);

				# we passed all three, keep it
				push @good_copies, $c if ($c);
				#$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			}

			$log->debug("\t".scalar(@good_copies)." (non-current) copies available for targeting...");

			my $old_best = $hold->current_copy;
			$hold->update({ current_copy => undef }) if ($old_best);
	
			if (!scalar(@good_copies)) {
				$log->info("\tNo (non-current) copies eligible to fill the hold.");
				if ( $old_best && grep { ''.$old_best->id eq ''.$_->id } @$all_copies ) {
					# the old copy is still available
					$log->debug("\tPushing current_copy back onto the targeting list");
					push @good_copies, $old_best;
				} else {
					# oops, old copy is not available
					$log->debug("\tcurrent_copy is no longer available for targeting... NEXT HOLD, PLEASE!");
					$hold->update( { prev_check_time => 'today' } );
					$self->method_lookup('open-ils.storage.transaction.commit')->run;
					push @successes, { hold => $hold->id, eligible_copies => 0, error => 'NO_TARGETS' };
					die "OK\n";
				}
			}

			#$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			my $prox_list = [];
			$$prox_list[0] =
			[
				grep {
					$_->circ_lib == $hold->pickup_lib
				} @good_copies
			];

			$all_copies = [grep {$_->circ_lib != $hold->pickup_lib } @good_copies];

			#$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			my $best = choose_nearest_copy($hold, $prox_list);
			$client->status( new OpenSRF::DomainObject::oilsContinueStatus );

			if (!$best) {
				$log->debug("\tNothing at the pickup lib, looking elsewhere among ".scalar(@$all_copies)." copies");
				$prox_list = create_prox_list( $self, $hold->pickup_lib, $all_copies );

				$client->status( new OpenSRF::DomainObject::oilsContinueStatus );

				$best = choose_nearest_copy($hold, $prox_list);
			}

			$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			if ($old_best) {
				# hold wasn't fulfilled, record the fact
			
				$log->info("\tHold was not (but should have been) fulfilled by ".$old_best->id);
				action::unfulfilled_hold_list->create(
						{ hold => ''.$hold->id,
						  current_copy => ''.$old_best->id,
						  circ_lib => ''.$old_best->circ_lib,
						});
			}

			if ($best) {
				$hold->update( { current_copy => ''.$best->id, prev_check_time => 'now' } );
				$log->debug("\tUpdating hold [".$hold->id."] with new 'current_copy' [".$best->id."] for hold fulfillment.");
			} elsif (
				$old_best &&
				action::hold_request
					->search_where(
						{ current_copy => $old_best->id,
						  fulfillment_time => undef,
						  cancel_time => undef,
						}       
					)
			) {     
				$hold->update( { prev_check_time => 'now', current_copy => ''.$old_best->id } );
				$log->debug( "\tRetargeting the previously targeted copy [".$old_best->id."]" );
			} else {
				$hold->update( { prev_check_time => 'now' } );
				$log->info( "\tThere were no targetable copies for the hold" );
			}

			$self->method_lookup('open-ils.storage.transaction.commit')->run;
			$log->info("\tProcessing of hold ".$hold->id." complete.");

			push @successes,
				{ hold => $hold->id,
				  old_target => ($old_best ? $old_best->id : undef),
				  eligible_copies => $copy_count,
				  target => ($best ? $best->id : undef) };

		} otherwise {
			my $e = shift;
			if ($e !~ /^OK/o) {
				$log->error("Processing of hold failed:  $e");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
				throw $e if ($e =~ /IS NOT CONNECTED TO THE NETWORK/o);
			}
		};
	}

	return \@successes;
}
__PACKAGE__->register_method(
	api_name	=> 'open-ils.storage.action.hold_request.copy_targeter',
	api_level	=> 1,
	method		=> 'new_hold_copy_targeter',
);

sub reservation_targeter {
	my $self = shift;
	my $client = shift;
	my $one_reservation = shift;

	local $OpenILS::Application::Storage::WRITE = 1;

	my $reservations;

	try {
		if ($one_reservation) {
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$reservations = [ booking::reservation->search_where( { id => $one_reservation, capture_time => undef, cancel_time => undef } ) ];
		} else {

			# find all the reservations needing targeting
			$reservations = [
                booking::reservation->search_where(
					{ current_resource => undef,
					  cancel_time => undef,
					  start_time => { '>' => 'now' }
                    },
                    { order_by => 'start_time' }
                )
            ];
		}
	} catch Error with {
		my $e = shift;
		die "Could not retrieve reservation requests:\n\n$e\n";
	};

	my @successes = ();
	for my $bresv (@$reservations) {
		try {
			#start a transaction if needed
			if ($self->method_lookup('open-ils.storage.transaction.current')->run) {
				$log->debug("Cleaning up after previous transaction\n");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			}
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$log->info("Processing reservation ".$bresv->id."...\n");

			#first, re-fetch the hold, to make sure it's not captured already
			$bresv->remove_from_object_index();
			$bresv = booking::reservation->retrieve( $bresv->id );

			die "OK\n" if (!$bresv or $bresv->capture_time or $bresv->cancel_time);

			my $end_time = $parser->parse_datetime( clense_ISO8601( $bresv->end_time ) );
			if (DateTime->compare($end_time, DateTime->now) < 0) {

				# cancel cause = un-targeted expiration
				$bresv->update( { cancel_time => 'now' } ); 
				$self->method_lookup('open-ils.storage.transaction.commit')->run;

				# tell A/T the reservation was cancelled
				my $fm_bresv = $bresv->to_fieldmapper;
				my $ses = OpenSRF::AppSession->create('open-ils.trigger');
				$ses->request('open-ils.trigger.event.autocreate', 
					'booking.reservation.cancel.expire_no_target', $fm_bresv, $fm_bresv->pickup_lib);

				die "OK\n";
			}

			my $possible_resources;

			# find all the potential resources
			if (!$bresv->target_resource) {
				my $filter = { type => $bresv->target_resource_type };
				my $attr_maps = [ booking::reservation_attr_value_map->search( reservation => $bresv->id) ];

				$filter->{attribute_values} = [ map { $_->attr_value } @$attr_maps ] if (@$attr_maps);

				$filter->{available} = [$bresv->start_time, $bresv->end_time];
				my $ses = OpenSRF::AppSession->create('open-ils.booking');
				$possible_resources = $ses->request('open-ils.booking.resources.filtered_id_list', undef, $filter)->gather(1);
			} else {
				$possible_resources = $bresv->target_resource;
			}

            my $all_resources = [ booking::resource->search( id => $possible_resources ) ];
			@$all_resources = grep { isTrue($_->type->transferable) || $_->owner.'' eq $bresv->pickup_lib.'' } @$all_resources;


            my @good_resources = ();
            my %conflicts = ();
            for my $res (@$all_resources) {
                unless (isTrue($res->type->catalog_item)) {
                    push @good_resources, $res;
                    next;
                }

                my $copy = [ asset::copy->search( deleted => 'f', barcode => $res->barcode )]->[0];

                unless ($copy) {
                    push @good_resources, $res;
                    next;
                }

                if ($copy->status->id == 0 || $copy->status->id == 7) {
                    push @good_resources, $res;
                    next;
                }

                if ($copy->status->id == 1) {
                    my $circs = [ action::circulation->search_where(
                        {target_copy => $copy->id, checkin_time => undef },
                        { order_by => 'id DESC' }
                    ) ];

                    if (@$circs) {
                        my $due_date = $circs->[0]->due_date;
			            $due_date = $parser->parse_datetime( clense_ISO8601( $due_date ) );
			            my $start_time = $parser->parse_datetime( clense_ISO8601( $bresv->start_time ) );
                        if (DateTime->compare($start_time, $due_date) < 0) {
                            $conflicts{$res->id} = $circs->[0]->to_fieldmapper;
                            next;
                        }
                        push @good_resources, $res;
                    }

                    next;
                }

                push @good_resources, $res if (isTrue($copy->status->holdable));
            }

			# let 'em know we're still working
			$client->status( new OpenSRF::DomainObject::oilsContinueStatus );
			
			# if we have no copies ...
			if (!@good_resources) {
				$log->info("\tNo resources available for targeting at all!\n");
				push @successes, { reservation => $bresv->id, eligible_copies => 0, error => 'NO_COPIES', conflicts => \%conflicts };

				$self->method_lookup('open-ils.storage.transaction.commit')->run;
				die "OK\n";
			}

			$log->debug("\t".scalar(@good_resources)." resources available for targeting...");

			my $prox_list = [];
			$$prox_list[0] =
			[
				grep {
					$_->owner == $bresv->pickup_lib
				} @good_resources
			];

			$all_resources = [grep {$_->owner != $bresv->pickup_lib } @good_resources];
			# $all_copies is now a list of copies not at the pickup library

			my $best = shift @good_resources;
			$client->status( new OpenSRF::DomainObject::oilsContinueStatus );

			if (!$best) {
				$log->debug("\tNothing at the pickup lib, looking elsewhere among ".scalar(@$all_resources)." resources");

				$prox_list =
                    map  { $_->[1] }
                    sort { $a->[0] <=> $b->[0] }
                    map  {
                        [   actor::org_unit_proximity->search_where(
                                { from_org => $bresv->pickup_lib.'', to_org => $_->owner.'' }
                            )->[0]->prox,
                            $_
                        ]
                    } @$all_resources;

				$client->status( new OpenSRF::DomainObject::oilsContinueStatus );

				$best = shift @$prox_list
			}

			if ($best) {
				$bresv->update( { current_resource => ''.$best->id } );
				$log->debug("\tUpdating reservation [".$bresv->id."] with new 'current_resource' [".$best->id."] for reservation fulfillment.");
			}

			$self->method_lookup('open-ils.storage.transaction.commit')->run;
			$log->info("\tProcessing of bresv ".$bresv->id." complete.");

			push @successes,
				{ reservation => $bresv->id,
				  current_resource => ($best ? $best->id : undef) };

		} otherwise {
			my $e = shift;
			if ($e !~ /^OK/o) {
				$log->error("Processing of bresv failed:  $e");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
				throw $e if ($e =~ /IS NOT CONNECTED TO THE NETWORK/o);
			}
		};
	}

	return \@successes;
}
__PACKAGE__->register_method(
	api_name	=> 'open-ils.storage.booking.reservation.resource_targeter',
	api_level	=> 1,
	method		=> 'reservation_targeter',
);

my $locations;
my $statuses;
my %cache = (titles => {}, cns => {});
sub hold_copy_targeter {
	my $self = shift;
	my $client = shift;
	my $check_expire = shift;
	my $one_hold = shift;

	$self->{user_filter} = OpenSRF::AppSession->create('open-ils.circ');
	$self->{user_filter}->connect;
	$self->{client} = $client;

	my $time = time;
	$check_expire ||= '12h';
	$check_expire = interval_to_seconds( $check_expire );

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time() - $check_expire);
	$year += 1900;
	$mon += 1;
	my $expire_threshold = sprintf(
		'%s-%0.2d-%0.2dT%0.2d:%0.2d:%0.2d-00',
		$year, $mon, $mday, $hour, $min, $sec
	);


	$statuses ||= [ config::copy_status->search(holdable => 't') ];

	$locations ||= [ asset::copy_location->search(holdable => 't') ];

	my $holds;

	%cache = (titles => {}, cns => {});

	try {
		if ($one_hold) {
			$holds = [ action::hold_request->search(id => $one_hold) ];
		} else {
			$holds = [ action::hold_request->search_where(
							{ capture_time => undef,
							  prev_check_time => { '<=' => $expire_threshold },
							},
							{ order_by => 'request_time,prev_check_time' } ) ];
			push @$holds, action::hold_request->search_where(
							{ capture_time => undef,
				  			  prev_check_time => undef,
							},
							{ order_by => 'request_time' } );
		}
	} catch Error with {
		my $e = shift;
		die "Could not retrieve uncaptured hold requests:\n\n$e\n";
	};

	for my $hold (@$holds) {
		try {
			#action::hold_request->db_Main->begin_work;
			if ($self->method_lookup('open-ils.storage.transaction.current')->run) {
				$client->respond("Cleaning up after previous transaction\n");
				$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			}
			$self->method_lookup('open-ils.storage.transaction.begin')->run( $client );
			$client->respond("Processing hold ".$hold->id."...\n");

			my $copies;

			$copies = $self->metarecord_hold_capture($hold) if ($hold->hold_type eq 'M');
			$self->{client}->status( new OpenSRF::DomainObject::oilsContinueStatus );

			$copies = $self->title_hold_capture($hold) if ($hold->hold_type eq 'T');
			$self->{client}->status( new OpenSRF::DomainObject::oilsContinueStatus );
			
			$copies = $self->volume_hold_capture($hold) if ($hold->hold_type eq 'V');
			$self->{client}->status( new OpenSRF::DomainObject::oilsContinueStatus );
			
			$copies = $self->copy_hold_capture($hold) if ($hold->hold_type eq 'C');

			unless (ref $copies || !@$copies) {
				$client->respond("\tNo copies available for targeting at all!\n");
			}

			my @good_copies;
			for my $c (@$copies) {
				next if ( grep {$c->id == $hold->current_copy} @good_copies);
				push @good_copies, $c if ($c);
			}

			$client->respond("\t".scalar(@good_copies)." (non-current) copies available for targeting...\n");

			my $old_best = $hold->current_copy;
			$hold->update({ current_copy => undef });
	
			if (!scalar(@good_copies)) {
				$client->respond("\tNo (non-current) copies available to fill the hold.\n");
				if ( $old_best && grep {$c->id == $hold->current_copy} @$copies ) {
					$client->respond("\tPushing current_copy back onto the targeting list\n");
					push @good_copies, asset::copy->retrieve( $old_best );
				} else {
					$client->respond("\tcurrent_copy is no longer available for targeting... NEXT HOLD, PLEASE!\n");
					next;
				}
			}

			my $prox_list;
			$$prox_list[0] = [grep {$_->circ_lib == $hold->pickup_lib } @good_copies];
			$copies = [grep {$_->circ_lib != $hold->pickup_lib } @good_copies];

			my $best = choose_nearest_copy($hold, $prox_list);

			if (!$best) {
				$prox_list = create_prox_list( $self, $hold->pickup_lib, $copies );
				$best = choose_nearest_copy($hold, $prox_list);
			}

			if ($old_best) {
				# hold wasn't fulfilled, record the fact
			
				$client->respond("\tHold was not (but should have been) fulfilled by ".$old_best->id.".\n");
				action::unfulfilled_hold_list->create(
						{ hold => ''.$hold->id,
						  current_copy => ''.$old_best->id,
						  circ_lib => ''.$old_best->circ_lib,
						});
			}

			if ($best) {
				$hold->update( { current_copy => ''.$best->id } );
				$client->respond("\tTargeting copy ".$best->id." for hold fulfillment.\n");
			}

			$hold->update( { prev_check_time => 'now' } );
			$client->respond("\tUpdating hold ".$hold->id." with new 'current_copy' for hold fulfillment.\n");

			$client->respond("\tProcessing of hold ".$hold->id." complete.\n");
			$self->method_lookup('open-ils.storage.transaction.commit')->run;

			#action::hold_request->dbi_commit;

		} otherwise {
			my $e = shift;
			$log->error("Processing of hold failed:  $e");
			$client->respond("\tProcessing of hold failed!.\n\t\t$e\n");
			$self->method_lookup('open-ils.storage.transaction.rollback')->run;
			#action::hold_request->dbi_rollback;
		};
	}

	$self->{user_filter}->disconnect;
	$self->{user_filter}->finish;
	delete $$self{user_filter};
	return undef;
}
__PACKAGE__->register_method(
	api_name        => 'open-ils.storage.action.hold_request.copy_targeter',
	api_level       => 0,
	stream		=> 1,
	method          => 'hold_copy_targeter',
);


sub copy_hold_capture {
	my $self = shift;
	my $hold = shift;
	my $cps = shift;

	if (!defined($cps)) {
		try {
			$cps = [ asset::copy->search( id => $hold->target ) ];
		} catch Error with {
			my $e = shift;
			die "Could not retrieve initial volume list:\n\n$e\n";
		};
	}

	my @copies = grep { $_->holdable } @$cps;

	for (my $i = 0; $i < @$cps; $i++) {
		next unless $$cps[$i];
		
		my $cn = $cache{cns}{$copies[$i]->call_number};
		my $rec = $cache{titles}{$cn->record};
		$copies[$i] = undef if ($copies[$i] && !grep{ $copies[$i]->status eq $_->id}@$statuses);
		$copies[$i] = undef if ($copies[$i] && !grep{ $copies[$i]->location eq $_->id}@$locations);
		$copies[$i] = undef if (
			!$copies[$i] ||
			!$self->{user_filter}->request(
				'open-ils.circ.permit_hold',
				$hold->to_fieldmapper, do {
					my $cp_fm = $copies[$i]->to_fieldmapper;
					$cp_fm->circ_lib( $copies[$i]->circ_lib->to_fieldmapper );
					$cp_fm->location( $copies[$i]->location->to_fieldmapper );
					$cp_fm->status( $copies[$i]->status->to_fieldmapper );
					$cp_fm;
				},
				{ title => $rec->to_fieldmapper,
				  usr => actor::user->retrieve($hold->usr)->to_fieldmapper,
				  requestor => actor::user->retrieve($hold->requestor)->to_fieldmapper,
				})->gather(1)
		);
		$self->{client}->status( new OpenSRF::DomainObject::oilsContinueStatus );
	}

	@copies = grep { $_ } @copies;

	my $count = @copies;

	return unless ($count);
	
	action::hold_copy_map->search( hold => $hold->id )->delete_all;
	
	my @maps;
	$self->{client}->respond( "\tMapping ".scalar(@copies)." eligable copies for hold ".$hold->id."\n");
	for my $c (@copies) {
		push @maps, action::hold_copy_map->create( { hold => $hold->id, target_copy => $c->id } );
	}
	$self->{client}->respond( "\tA total of ".scalar(@maps)." mapping were created for hold ".$hold->id."\n");

	return \@copies;
}


sub choose_nearest_copy {
	my $hold = shift;
	my $prox_list = shift;

	for my $p ( 0 .. int( scalar(@$prox_list) - 1) ) {
		next unless (ref $$prox_list[$p]);

		my @capturable = grep { $_->status == 0 || $_->status == 7 } @{ $$prox_list[$p] };
		next unless (@capturable);

		my $rand = int(rand(scalar(@capturable)));
		my %seen = ();
		while (my ($c) = splice(@capturable, $rand, 1)) {
			return $c if !exists($seen{$c->id}) && ( OpenILS::Utils::PermitHold::permit_copy_hold(
				{ title => $c->call_number->record->to_fieldmapper,
				  title_descriptor => $c->call_number->record->record_descriptor->next->to_fieldmapper,
				  patron => $hold->usr->to_fieldmapper,
				  copy => $c->to_fieldmapper,
				  requestor => $hold->requestor->to_fieldmapper,
				  request_lib => $hold->request_lib->to_fieldmapper,
				  pickup_lib => $hold->pickup_lib->id,
				  retarget => 1
				}
			));
			$seen{$c->id}++;

			last unless(@capturable);
			$rand = int(rand(scalar(@capturable)));
		}
	}
}

sub create_prox_list {
	my $self = shift;
	my $lib = shift;
	my $copies = shift;

	my @prox_list;
	for my $cp (@$copies) {
		my ($prox) = $self->method_lookup('open-ils.storage.asset.copy.proximity')->run( $cp, $lib );
		next unless (defined($prox));
		$prox_list[$prox] = [] unless defined($prox_list[$prox]);
		push @{$prox_list[$prox]}, $cp;
	}
	return \@prox_list;
}

sub volume_hold_capture {
	my $self = shift;
	my $hold = shift;
	my $vols = shift;

	if (!defined($vols)) {
		try {
			$vols = [ asset::call_number->search( id => $hold->target ) ];
			$cache{cns}{$_->id} = $_ for (@$vols);
		} catch Error with {
			my $e = shift;
			die "Could not retrieve initial volume list:\n\n$e\n";
		};
	}

	my @v_ids = map { $_->id } @$vols;

	my $cp_list;
	try {
		$cp_list = [ asset::copy->search( call_number => \@v_ids ) ];
	
	} catch Error with {
		my $e = shift;
		warn "Could not retrieve copy list:\n\n$e\n";
	};

	$self->copy_hold_capture($hold,$cp_list) if (ref $cp_list and @$cp_list);
}

sub title_hold_capture {
	my $self = shift;
	my $hold = shift;
	my $titles = shift;

	if (!defined($titles)) {
		try {
			$titles = [ biblio::record_entry->search( id => $hold->target ) ];
			$cache{titles}{$_->id} = $_ for (@$titles);
		} catch Error with {
			my $e = shift;
			die "Could not retrieve initial title list:\n\n$e\n";
		};
	}

	my @t_ids = map { $_->id } @$titles;
	my $cn_list;
	try {
		($cn_list) = $self->method_lookup('open-ils.storage.direct.asset.call_number.search.record.atomic')->run( \@t_ids );
	
	} catch Error with {
		my $e = shift;
		warn "Could not retrieve volume list:\n\n$e\n";
	};

	$cache{cns}{$_->id} = $_ for (@$cn_list);

	$self->volume_hold_capture($hold,$cn_list) if (ref $cn_list and @$cn_list);
}

sub metarecord_hold_capture {
	my $self = shift;
	my $hold = shift;

	my $titles;
	try {
		$titles = [ metabib::metarecord_source_map->search( metarecord => $hold->target) ];
	
	} catch Error with {
		my $e = shift;
		die "Could not retrieve initial title list:\n\n$e\n";
	};

	try {
		my @recs = map {$_->record} metabib::record_descriptor->search( record => $titles, item_type => [split '', $hold->holdable_formats] ); 

		$titles = [ biblio::record_entry->search( id => \@recs ) ];
	
	} catch Error with {
		my $e = shift;
		die "Could not retrieve format-pruned title list:\n\n$e\n";
	};


	$cache{titles}{$_->id} = $_ for (@$titles);
	$self->title_hold_capture($hold,$titles) if (ref $titles and @$titles);
}

1;