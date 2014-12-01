def upgrade ta, td, a, d
  a['max_pool_size'] = ta['max_pool_size']
  a['max_overflow'] = ta['max_overflow']
  a['pool_timeout'] = ta['pool_timeout']
  return a, d
end

def downgrade ta, td, a, d
  a.delete 'max_pool_size'
  a.delete 'max_overflow'
  a.delete 'pool_timeout'
  return a, d
end
