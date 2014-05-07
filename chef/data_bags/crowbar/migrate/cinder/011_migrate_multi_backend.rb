def upgrade ta, td, a, d
  a['volume_defaults'] = a['volume']
  a['volume'] = []
  backend_driver = a['volume_defaults']['volume_type']
  # volume_type got renamed to volume_driver
  a['volume_defaults']['volume_driver'] = a['volume_defaults']['volume_type']
  a['volume_defaults'].delete 'volume_type'
  # Disable Multi backend support on migration
  a['volume_defaults']['use_multi_backend'] = false

  a['volume'] << {
    "backend_name" => "default",
    "backend_driver" => backend_driver,
    a['volume_defaults']['volume_driver'] => a['volume_defaults'][backend_driver]
  }
  return a, d
end


def downgrade ta, td, a, d
  # preserve first volume backend
  current_volume_driver = a['volume'][0]['backend_driver']
  current_volume = a['volume'][0][current_volume_driver]
  a['volume'] = a['volume_defaults']
  a['volume'][current_volume_driver] = current_volume
  # Rename volume_driver back to volume_type
  a['volume']['volume_type'] = current_volume_driver
  a['volume'].delete 'volume_driver'
  a['volume'].delete 'use_multi_backend'
  a.delete 'volume_defaults'

  return a, d
end
