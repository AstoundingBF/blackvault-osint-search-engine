require 'cassandra'

cluster = Cassandra.cluster
session = cluster.connect('bigdata')

# Insert sample data into the users table
session.execute("INSERT INTO users (id, email, password, firstName, lastName, address, zipcode, age, source) VALUES (1, 'john@example.com', 'password123', 'John', 'Doe', '123 Main St', '12345', 30, 'website')")
session.execute("INSERT INTO users (id, email, password, firstName, lastName, address, zipcode, age, source) VALUES (2, 'jane@example.com', 'password456', 'Jane', 'Smith', '456 Elm St', '67890', 25, 'mobile app')")
session.execute("INSERT INTO users (id, email, password, firstName, lastName, address, zipcode, age, source) VALUES (3, 'bob@example.com', 'password789', 'Bob', 'Johnson', '789 Oak St', '54321', 40, 'website')")
