$compute = hiera('tripleo::profile::base::nova::nova_compute_enabled', false)

if $compute {
  mount { "/var/lib/nova/instances":
    device  => "192.0.2.1:/exports/nova",
    fstype  => "nfs",
    ensure  => "mounted",
    options => "intr,context=system_u:object_r:nova_var_lib_t:s0",
    atboot  => true,
  }
}
