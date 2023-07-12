from cassandra.cluster import Cluster
from cassandra.query import BatchStatement
import csv
import sys

csv.field_size_limit(sys.maxsize)

def create_column_if_not_exists(keyspace, table, column):
    # Connect to the cluster
    cluster = Cluster(['localhost'])
    session = cluster.connect()

    # Set the keyspace
    session.set_keyspace(keyspace)

    # Check if the column exists in the table
    select_query = f"SELECT {column} FROM {table} LIMIT 1"
    try:
        session.execute(select_query)
    except Exception as e:
        if "Undefined column name" in str(e):
            # Add the column to the table
            alter_table_query = f"ALTER TABLE {table} ADD {column} TEXT"
            session.execute(alter_table_query)

    # Disconnect from the cluster
    session.shutdown()

def import_data_from_csv(keyspace, table, csv_file):
    # Connect to the cluster
    cluster = Cluster(['localhost'])
    session = cluster.connect()

    # Set the keyspace
    session.set_keyspace(keyspace)

    # Create the table if it doesn't exist
    create_table_query = f"""
        CREATE TABLE IF NOT EXISTS {table} (
            ID INT PRIMARY KEY,
            source TEXT,
            firstname TEXT,
            lastname TEXT,
            email TEXT,
            dob TEXT,
            address TEXT
        )
    """
    session.execute(create_table_query)

    # Prepare the insert statement
    insert_query = f"""
        INSERT INTO {table} (ID, source, firstname, lastname, email, dob, address)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """
    prepared_statement = session.prepare(insert_query)

    # Open the CSV file
    with open(csv_file, 'r') as file:
        reader = csv.DictReader(file)
        total_rows = sum(1 for _ in reader)  # Count the total number of rows

        file.seek(0)  # Reset the file pointer
        reader = csv.DictReader(file)  # Create a new reader

        # Check if each column name exists and add it if necessary
        for column in reader.fieldnames:
            create_column_if_not_exists(keyspace, table, column)

        # Prepare the batch statement
        batch = BatchStatement()

        # Import data from each row of the CSV
        imported_rows = 0
        for row in reader:
            record = {
                'id': int(row['ID']),
                'source': row['source'],
                'firstname': row['firstName'],
                'lastname': row['lastName'],
                'email': row['Email'],
                'dob': row['DOB'],
                'address': row['address']
            }
            batch.add(prepared_statement, tuple(record.values()))
            imported_rows += 1

            # Execute the batch if it reaches the specified size
            if imported_rows % 1000 == 0:
                session.execute(batch)
                batch.clear()
                print(f"Imported {imported_rows}/{total_rows} rows into {keyspace}.{table}")

        # Insert any remaining rows in the last batch
        if batch:
            session.execute(batch)
            batch.clear()

    # Disconnect from the cluster
    session.shutdown()

if __name__ == '__main__':
    # Specify the keyspace, table, and CSV file path
    keyspace = 'bigdata'
    table = 'users'
    csv_file = 'data.csv'

    # Call the import function
    import_data_from_csv(keyspace, table, csv_file)
